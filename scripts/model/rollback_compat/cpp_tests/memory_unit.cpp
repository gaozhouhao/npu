// Standalone tests of the C++ DDR transition logic, using inert DUT port stubs.
#define main graph_driver_entry
#include "../graph_driver.cpp"
#undef main
int main() {
    char a0[]="memory_unit",a1[]="+DDR_HEX=scripts/model/rollback_compat/cpp_tests/input.hex";
    char a2[]="+IMAGE_WORDS=1600",a3[]="+DESC_BASE=0",a4[]="+DESC_COUNT=1",a5[]="+LOGITS_BASE=0";
    char a6[]="+LOGITS_COUNT=1",a7[]="+LAYER_CHECKS=scripts/model/rollback_compat/cpp_tests/layers.txt",a8[]="+DDR_RD_LATENCY=2";
    char* argv[]={a0,a1,a2,a3,a4,a5,a6,a7,a8};Config cfg(9,argv);Memory m(cfg);Vnpu_top d;
    auto edge=[&] {Memory::Bus b(d);m.update(b,false);m.drive(d);};
    m.drive(d);require(d.m_axi_arready,"initial AR ready");
    d.m_axi_arvalid=1;d.m_axi_araddr=0;d.m_axi_arlen=1;d.m_axi_arsize=3;d.m_axi_arburst=1;edge();
    require(!d.m_axi_arready&&!d.m_axi_rvalid&&m.q.rd_wait==2,"AR latency start");
    d.m_axi_arvalid=0;d.m_axi_rready=1;edge();require(!d.m_axi_rvalid&&m.q.rd_wait==1,"read wait first");
    edge();require(d.m_axi_rvalid&&!d.m_axi_rlast&&d.m_axi_rdata==(uint64_t(1)<<32),"first beat after two waits");
    d.m_axi_rready=0;edge();require(m.q.reads==0&&d.m_axi_rvalid,"read backpressure");
    d.m_axi_rready=1;edge();require(m.q.reads==1&&d.m_axi_rlast&&d.m_axi_rdata==((uint64_t(3)<<32)|2),"second burst beat");
    edge();require(m.q.reads==2&&!d.m_axi_rvalid&&d.m_axi_arready,"last burst beat");
    d.m_axi_awvalid=1;d.m_axi_awaddr=16;d.m_axi_awlen=0;d.m_axi_awsize=2;d.m_axi_awburst=1;
    d.m_axi_wvalid=1;d.m_axi_wlast=1;d.m_axi_wdata=0xaabbccdd;d.m_axi_wstrb=5;d.m_axi_bready=1;edge();
    require(m.q.writes==0&&d.m_axi_wready,"AW and W use old wready");
    d.m_axi_awvalid=0;edge();require(m.q.writes==1&&m.q.written==2&&m.mem[4]==0x00bb00dd&&d.m_axi_bvalid,"byte strobes and zero-latency B");
    require(!d.m_axi_awready,"B blocks new AW");d.m_axi_wvalid=0;edge();require(!d.m_axi_bvalid&&d.m_axi_awready,"B cannot be consumed in same edge it is generated");
    cfg.wr_latency=2;Memory delayed(cfg);delayed.drive(d);d.m_axi_awvalid=1;
    Memory::Bus aw(d);delayed.update(aw,false);delayed.drive(d);d.m_axi_awvalid=0;d.m_axi_wvalid=1;
    Memory::Bus w(d);delayed.update(w,false);delayed.drive(d);require(delayed.q.b_pending&&!d.m_axi_bvalid&&delayed.q.b_wait==2,"delayed B start");
    d.m_axi_wvalid=0;Memory::Bus idle(d);delayed.update(idle,false);delayed.drive(d);require(delayed.q.b_wait==1&&!d.m_axi_bvalid,"delayed B wait");
    Memory::Bus idle2(d);delayed.update(idle2,false);delayed.drive(d);require(d.m_axi_bvalid&&!delayed.q.b_pending,"delayed B response");
    bool rejected=false;d.m_axi_arvalid=1;d.m_axi_araddr=4088;d.m_axi_arlen=1;Memory::Bus crossing(d);
    try {delayed.update(crossing,false);}catch(const std::runtime_error&){rejected=true;}require(rejected,"reject 4KiB crossing");
    delayed.update(crossing,true);require(!delayed.q.rd_active&&!delayed.q.wr_active&&!delayed.q.bvalid&&!delayed.q.writes,"synchronous reset");
    std::puts("PASS: C++ DDR first-beat latency, burst/backpressure, old-state AW/W/B ordering, byte strobes, delayed B, page bounds and reset");
}
