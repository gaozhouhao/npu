// Cycle-exact port of sim/tb/system/graph_model_npu_tb.sv. No clocks are skipped.
#include "Vnpu_top.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>
#define U(x) static_cast<unsigned long long>(x)

static void require(bool ok, const std::string& message) {
    if (!ok) throw std::runtime_error(message);
}
static void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}
static std::vector<uint32_t> load_hex(const std::string& path, uint64_t count) {
    std::ifstream in(path); require(bool(in), "Cannot open hex file " + path);
    std::vector<uint32_t> words(count);
    for (uint64_t i=0; i<count; ++i) {
        uint64_t word; require(bool(in >> std::hex >> word) && word<=UINT32_MAX,
                               "Missing or invalid hex word in " + path);
        words[i]=uint32_t(word);
    }
    std::string extra; require(!(in >> extra), "Extra hex words in " + path);
    return words;
}
struct Config {
    std::string input, checks, dump;
    uint64_t words=0, desc_base=0, descriptors=0, logits_base=0, logits=1001;
    uint64_t max_cycles=4000000000ULL, rd_latency=20, wr_latency=0;
    Config(int argc, char** argv) {
        std::unordered_map<std::string,std::string> args;
        for(int i=1;i<argc;++i) { std::string a=argv[i]; auto p=a.find('=');
            if(a.size()>1 && a[0]=='+' && p!=std::string::npos) args[a.substr(1,p-1)]=a.substr(p+1); }
        auto text=[&](const char* key,bool required) { auto it=args.find(key);
            require(!required || it!=args.end(),std::string("Missing +")+key); return it==args.end()?std::string():it->second; };
        auto number=[&](const char* key,uint64_t fallback,int base,bool required) {
            auto value=text(key,required); if(value.empty())return fallback;
            size_t end=0; auto parsed=std::stoull(value,&end,base);
            require(end==value.size(),std::string("Invalid +")+key); return uint64_t(parsed); };
        input=text("DDR_HEX",true); checks=text("LAYER_CHECKS",true); dump=text("DDR_DUMP",false);
        words=number("IMAGE_WORDS",0,10,true);desc_base=number("DESC_BASE",0,16,true);
        descriptors=number("DESC_COUNT",0,10,true);logits_base=number("LOGITS_BASE",0,16,true);
        logits=number("LOGITS_COUNT",logits,10,false);max_cycles=number("MAX_CYCLES",max_cycles,10,false);
        rd_latency=number("DDR_RD_LATENCY",rd_latency,10,false);wr_latency=number("DDR_WR_LATENCY",wr_latency,10,false);
        require(words && words<=8388608 && descriptors && descriptors<=65535 &&
                !(desc_base&63) && desc_base<words*4 && descriptors*64<=words*4-desc_base &&
                logits && logits_base<words*4 && logits<=words*4-logits_base && max_cycles &&
                rd_latency<=UINT32_MAX && wr_latency<=UINT32_MAX,"Invalid model configuration");
    }
};
struct Memory {
    struct State {
        bool rd_active=false, wr_active=false, b_pending=false, bvalid=false;
        uint64_t rd_addr=0, wr_addr=0, reads=0, writes=0, written=0;
        uint32_t rd_left=0, wr_left=0, rd_id=0, wr_id=0, rd_wait=0, b_wait=0;
    } q;
    struct Bus {
        bool ar, aw, w, r, b, wlast; uint64_t araddr, awaddr;
        uint32_t arlen, awlen, arsize, awsize, arburst, awburst, arid, awid, wdata, wstrb;
        explicit Bus(const Vnpu_top& d):
          ar(d.m_axi_arvalid&&d.m_axi_arready),aw(d.m_axi_awvalid&&d.m_axi_awready),
          w(d.m_axi_wvalid&&d.m_axi_wready),r(d.m_axi_rvalid&&d.m_axi_rready),
          b(d.m_axi_bvalid&&d.m_axi_bready),wlast(d.m_axi_wlast),araddr(d.m_axi_araddr),awaddr(d.m_axi_awaddr),
          arlen(d.m_axi_arlen),awlen(d.m_axi_awlen),arsize(d.m_axi_arsize),awsize(d.m_axi_awsize),
          arburst(d.m_axi_arburst),awburst(d.m_axi_awburst),arid(d.m_axi_arid),awid(d.m_axi_awid),
          wdata(d.m_axi_wdata),wstrb(d.m_axi_wstrb) {}
    };
    const Config& cfg; std::vector<uint32_t> mem;
    explicit Memory(const Config& c):cfg(c),mem(load_hex(c.input,c.words)) {}
    uint8_t byte(uint64_t address) const { return uint8_t(mem.at(address>>2) >> (8*(address&3))); }
    void drive(Vnpu_top& d) const {
        d.m_axi_arready=!q.rd_active; d.m_axi_rid=q.rd_id;
        d.m_axi_rvalid=q.rd_active && !q.rd_wait; d.m_axi_rlast=q.rd_left==1;
        const uint64_t index=q.rd_addr>>2;
        d.m_axi_rdata=uint64_t(mem[index]) | (uint64_t(mem[index+1])<<32); d.m_axi_rresp=0;
        d.m_axi_awready=!q.wr_active&&!q.b_pending&&!q.bvalid;d.m_axi_wready=q.wr_active;
        d.m_axi_bid=q.wr_id;d.m_axi_bvalid=q.bvalid;d.m_axi_bresp=0;
    }
    void update(const Bus& b, bool reset) {
        if(reset) {q=State{};return;}
        const State old=q; State n=old;
        // All decisions use old q, matching simultaneous SystemVerilog NBA assignments.
        if(b.ar) {
            const uint64_t bytes=(uint64_t(b.arlen)+1)*8;
            require(b.arsize==3 && b.arburst==1 && !(b.araddr&7) && b.araddr<cfg.words*4 &&
                    bytes<=cfg.words*4-b.araddr && (b.araddr&4095)+bytes<=4096,"Bad AXI AR");
            n.rd_active=true;n.rd_wait=uint32_t(cfg.rd_latency);n.rd_addr=b.araddr;
            n.rd_left=b.arlen+1;n.rd_id=b.arid;
        } else if(old.rd_active && old.rd_wait) --n.rd_wait;
        else if(b.r) {++n.reads;if(old.rd_left==1)n.rd_active=false;
            else {n.rd_addr+=8;--n.rd_left;} }
        if(b.aw) {
            const uint64_t bytes=(uint64_t(b.awlen)+1)*4;
            require(b.awsize==2 && b.awburst==1 && !(b.awaddr&3) && b.awaddr<cfg.words*4 &&
                    bytes<=cfg.words*4-b.awaddr && (b.awaddr&4095)+bytes<=4096,"Bad AXI AW");
            n.wr_active=true;n.wr_addr=b.awaddr;n.wr_left=b.awlen+1;n.wr_id=b.awid;
        }
        if(old.b_pending) {if(old.b_wait>1)--n.b_wait;
            else {n.b_wait=0;n.b_pending=false;n.bvalid=true;} }
        if(b.w) {
            require(b.wlast==(old.wr_left==1) && old.wr_addr<cfg.words*4,"Invalid AXI W");
            uint32_t& word=mem[old.wr_addr>>2];
            for(unsigned lane=0;lane<4;++lane)if(b.wstrb&(1U<<lane)) {
                const uint32_t mask=255U<<(8*lane);word=(word&~mask)|(b.wdata&mask);++n.written; }
            ++n.writes;
            if(old.wr_left==1) {n.wr_active=false;
                if(!cfg.wr_latency)n.bvalid=true;
                else {n.b_pending=true;n.b_wait=uint32_t(cfg.wr_latency);} }
            else {n.wr_addr+=4;--n.wr_left;}
        }
        if(b.b)n.bvalid=false; // Last assignment wins, exactly as in the SV model.
        q=n;
    }
};
struct Driver {
    VerilatedContext& context; Vnpu_top& dut; const Config& cfg; Memory memory;
    std::ifstream checks; uint64_t previous_written=0;uint32_t checked=0;
    Driver(VerilatedContext& c,Vnpu_top& d,const Config& f):context(c),dut(d),cfg(f),memory(f),checks(f.checks) {
        require(bool(checks),"Cannot open layer metadata "+cfg.checks);
        dut.clk=0;dut.reset=1;dut.start=0;dut.desc_base=cfg.desc_base;dut.desc_count=cfg.descriptors;
        memory.drive(dut);dut.eval();
    }
    void layer_check() {
        if(dut.reset) {checked=0;previous_written=0;return;}
        if(!dut.perf_layer_done_pulse)return;
        require(!memory.q.wr_active&&!memory.q.b_pending&&!memory.q.bvalid,"Layer completed with outstanding writes");
        uint32_t index,opcode;uint64_t address,bytes;std::string path;
        require(bool(checks>>std::dec>>index>>opcode>>std::hex>>address>>std::dec>>bytes>>path),"Malformed/missing layer metadata");
        require(index==dut.perf_completed_layer_index && index==checked && opcode==dut.perf_completed_layer_opcode,"Layer metadata mismatch");
        require(bytes && bytes<=262144ULL*4 && address<cfg.words*4 && bytes<=cfg.words*4-address,"Golden range outside memory/scratch");
        auto expected=load_hex(path,(bytes+3)/4);
        for(uint64_t i=0;i<bytes;++i) {
            uint8_t gold=uint8_t(expected[i>>2]>>(8*(i&3))),actual=memory.byte(address+i);
            if(actual!=gold)throw std::runtime_error("Layer "+std::to_string(index)+" mismatch at byte "+std::to_string(i)+" RTL="+std::to_string(actual)+" expected="+std::to_string(gold));
        }
        std::printf("LAYER_CHECK PASS index=%u opcode=%u checked_bytes=%llu\n",index,opcode,U(bytes));
        std::printf("PERF_LAYER,index=%u,opcode=%u,cycles=%llu,executor=%llu,pool=%llu,ar=%llu,read_beats=%llu,aw=%llu,write_beats=%llu,written_bytes=%llu\n",index,opcode,
          U(dut.perf_completed_layer_cycles),U(dut.perf_completed_layer_executor_cycles),U(dut.perf_completed_layer_pool_cycles),
          U(dut.perf_completed_layer_ar),U(dut.perf_completed_layer_r_beats),U(dut.perf_completed_layer_aw),U(dut.perf_completed_layer_w_beats),
          U(dut.perf_written_bytes-previous_written));
        std::fflush(stdout);previous_written=dut.perf_written_bytes;++checked;
    }
    void tick() {
        // Starting at settled clk=0, sample the *old* bus before the active edge.
        const Memory::Bus old_bus(dut);const bool old_reset=dut.reset;
        context.timeInc(5);dut.clk=1;dut.eval();
        memory.update(old_bus,old_reset);memory.drive(dut);dut.eval();
        context.timeInc(5);dut.clk=0;dut.eval();layer_check();
        if(context.gotFinish())throw std::runtime_error("RTL stopped before completed inference");
    }
    void run() {
        std::printf("DDR_READ_LATENCY_CYCLES,%llu\nDDR_WRITE_LATENCY_CYCLES,%llu\n",U(cfg.rd_latency),U(cfg.wr_latency));
        std::printf("MODEL_CONFIG,image_words=%llu,descriptor_count=%llu,logits_count=%llu,max_cycles=%llu\n",U(cfg.words),U(cfg.descriptors),U(cfg.logits),U(cfg.max_cycles));std::fflush(stdout);
        for(int i=0;i<5;++i)tick();dut.reset=0;dut.eval();
        tick();dut.start=1;dut.eval();tick();dut.start=0;dut.eval();
        uint64_t cycles=0;
        while(!dut.done && cycles<cfg.max_cycles) {tick();++cycles;
            if(dut.error)throw std::runtime_error("Model inference ERROR after "+std::to_string(cycles)+" cycles");}
        require(dut.done,"Model inference TIMEOUT after "+std::to_string(cycles)+" cycles");
        tick();tick();
        require(!dut.busy&&!dut.error&&!memory.q.rd_active&&!memory.q.wr_active&&!memory.q.b_pending&&!memory.q.bvalid&&
                !dut.m_axi_arvalid&&!dut.m_axi_awvalid&&!dut.m_axi_wvalid&&!dut.m_axi_rvalid&&!dut.m_axi_bvalid,"Model done with outstanding traffic");
        require(checked==cfg.descriptors,"Incomplete checked layer count");
        require(dut.perf_r_beats==memory.q.reads && dut.perf_w_beats==memory.q.writes && dut.perf_written_bytes==memory.q.written,"Independent AXI counters differ");
        std::printf("PERF_COUNTER_CHECK,PASS\n");
        std::printf("PERF_TOTAL,cycles=%llu,executor=%llu,pool=%llu,ar=%llu,read_beats=%llu,aw=%llu,write_beats=%llu,written_bytes=%llu\n",
          U(dut.perf_total_cycles),U(dut.perf_executor_cycles),U(dut.perf_pool_cycles),U(dut.perf_ar_transactions),U(dut.perf_r_beats),U(dut.perf_aw_transactions),U(dut.perf_w_beats),U(dut.perf_written_bytes));
        std::printf("PERF_WAIT,ar_stall=%llu,r_wait=%llu,aw_stall=%llu,w_stall=%llu,b_wait=%llu\n",U(dut.perf_ar_stall_cycles),U(dut.perf_r_wait_cycles),U(dut.perf_aw_stall_cycles),U(dut.perf_w_stall_cycles),U(dut.perf_b_wait_cycles));
        checks>>std::ws;require(checks.peek()==std::char_traits<char>::eof(),"Extra layer metadata after final layer");
        uint64_t prediction=0;int best=-129;
        for(uint64_t i=0;i<cfg.logits;++i) {uint8_t raw=memory.byte(cfg.logits_base+i);int value=(raw&128)?int(raw)-256:int(raw);
            if(value>best) {best=value;prediction=i;} }
        std::printf("MODEL_NPU FINISHED: cycles=%llu read_beats=%llu write_beats=%llu written_bytes=%llu logits_count=%llu top1=%llu descriptors=%llu layers=%u\n",
          U(dut.perf_total_cycles),U(memory.q.reads),U(memory.q.writes),U(memory.q.written),U(cfg.logits),U(prediction),U(cfg.descriptors),checked);std::fflush(stdout);
        if(!cfg.dump.empty()) {
            std::FILE* out=std::fopen(cfg.dump.c_str(),"w");require(out,"Cannot open DDR dump "+cfg.dump);
            for(uint32_t word:memory.mem)std::fprintf(out,"%08x\n",word);
            require(std::fclose(out)==0,"Cannot finish DDR dump");
            std::printf("DDR SNAPSHOT FINISHED: words=%llu file=%s\n",U(cfg.words),cfg.dump.c_str());
        }
    }
};
int main(int argc,char** argv) {
    try {VerilatedContext context;context.commandArgs(argc,argv);Config cfg(argc,argv);
        Vnpu_top dut(&context);Driver driver(context,dut,cfg);driver.run();dut.final();return 0;}
    catch(const std::exception& error) {std::fprintf(stderr,"Fatal: C++ graph driver: %s\n",error.what());return 1;}
}
