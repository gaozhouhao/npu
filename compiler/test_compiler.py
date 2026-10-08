"""ABI regression and negative tests; no RTL testbench is generated."""
import copy
import json
import struct
import tempfile
import unittest
from pathlib import Path
import numpy as np
from target import HERE, REPO, encode, decode, load_target, MemoryPlan, validate_descriptor
from verify_model import rtl_requant, verify_files, execute, compare_rtl_dump


class CompilerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cfg,_=load_target(HERE/'npu_config.json')
        cls.out=REPO/'artifacts/npu'
        cls.report=json.loads((cls.out/'compilation_report.json').read_text())

    def test_literal_descriptor_abi(self):
        d=copy.deepcopy(self.report['descriptors'][0])
        raw=encode(d)
        self.assertEqual(raw[:16],struct.pack('<4I',0x702,784,8,9))
        self.assertEqual(raw[40:52],struct.pack('<3I',0x001c001c,0x03030001,0x01010101))
        d['a']=0x1234567800001000
        self.assertEqual(encode(d)[16:24],bytes.fromhex('0010000078563412'))
        self.assertEqual(decode(encode(d)),d)

    def test_fc_padding_required(self):
        d=copy.deepcopy(self.report['descriptors'][4])
        d['m'],d['n']=1,10
        with self.assertRaisesRegex(ValueError,'Partial M/N'):
            validate_descriptor(d,self.cfg)

    def test_byte_stride_alignment(self):
        d=copy.deepcopy(self.report['descriptors'][4])
        for stride in (783,780):
            d['words10_12'][1]=stride
            with self.assertRaises(ValueError):
                validate_descriptor(d,self.cfg)

    def test_pool_flags_rejected(self):
        d=copy.deepcopy(self.report['descriptors'][1])
        d['flags']=1
        with self.assertRaisesRegex(ValueError,'pooling'):
            validate_descriptor(d,self.cfg)

    def test_conv_geometry_rejected(self):
        d=copy.deepcopy(self.report['descriptors'][0])
        d['k']=12
        with self.assertRaisesRegex(ValueError,'geometry'):
            validate_descriptor(d,self.cfg)

    def test_config_mismatch_rejected(self):
        cfg=dict(self.cfg,pe_rows=8)
        with tempfile.TemporaryDirectory(dir=HERE, prefix='test_config_') as td:
            path=Path(td)/'config.json'
            path.write_text(json.dumps(cfg))
            with self.assertRaisesRegex(ValueError,'pe_rows'):
                load_target(path)

    def test_capacity_and_dma_bounds(self):
        p=MemoryPlan(dict(self.cfg,ddr_capacity_bytes=16))
        p.allocate('row',12,[12],'i1','row')
        with self.assertRaisesRegex(ValueError,'capacity'):
            p.allocate('overflow',8,[8],'i1','row')
        with self.assertRaisesRegex(ValueError,'escapes'):
            p.validate_access(8,8,'row')

    def test_rounding_and_saturation(self):
        values=np.array([-1000,-255,-7,-1,0,1,7,255,1000])
        np.testing.assert_array_equal(rtl_requant(np,values,1,1,False),[-128,-128,-4,-1,0,1,4,127,127])
        np.testing.assert_array_equal(rtl_requant(np,values,1,0),np.clip(values,0,127))
        with self.assertRaises(ValueError):
            rtl_requant(np,values,2**31,30)

    def test_all_serialized_images(self):
        results=verify_files(np,self.out)
        self.assertEqual([x['predicted'] for x in results],[7,2,1,0])

    def test_dump_comparator_detects_corruption(self):
        plan=json.loads((self.out/'memory_map.json').read_text())
        _,memory=execute(np,(self.out/'ddr/image_0000.bin').read_bytes(),(self.out/'commands.bin').read_bytes(),plan)
        with tempfile.TemporaryDirectory(dir=HERE, prefix='test_dump_') as td:
            dump=Path(td)/'dump.bin'
            dump.write_bytes(memory)
            compare_rtl_dump(np,self.out,dump,'image_0000')
            memory[plan['regions']['fc_output']['address']]^=1
            dump.write_bytes(memory)
            with self.assertRaisesRegex(ValueError,'fc: first mismatch'):
                compare_rtl_dump(np,self.out,dump,'image_0000')


if __name__=='__main__':
    unittest.main(verbosity=2)
