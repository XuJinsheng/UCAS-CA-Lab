

`include "common.svh"
`default_nettype none

interface fetch_decode_interface;
    logic valid, allowin;
    data_t pc, inst;
    exception_t exception;
    modport fetch(input allowin, output valid, pc, inst, exception);
    modport decode(output allowin, input valid, pc, inst, exception);
endinterface

interface predictor_fetch_interface;
    logic inst_valid;
    data_t inst, inst_pc;

    logic  target_valid;
    data_t target_pc;

    logic  flush;
    modport predictor(input inst_valid, inst, inst_pc, output flush, target_valid, target_pc);
    modport fetch(output inst_valid, inst, inst_pc, input flush, target_valid, target_pc);
endinterface

interface CSR_ROB_fetch_interface;
    logic target_valid, target_valid2;
    data_t target_pc, target_pc2;
    data_t retire_valid;
    modport fetch(input target_valid, target_pc, retire_valid, target_valid2, target_pc2);
    modport ROB(output retire_valid, target_valid2, target_pc2);
    modport CSR(output target_valid, target_pc);
endinterface

/*
	icache设置为flush后的第一个周期也不接受请求
	如果cache传来分支指令，那么data->指令进队列，进bru：bru判断为分支指令，拉高flush，拉低取指，以后的分支指令不进队且放弃->inst_que不动，pc_que恢复至inst_que，working置0
	正常给decoder传指令
	如果分支计算完毕，predictor信号拉高->working置1，更新pc：取指信号拉高
*/
module fetch_unit (
    input wire clk,
    input wire rst,

    request_interface.sender memory_read_req[2],
    data_transfer_interface.receiver memory_read_data[2],

    fetch_decode_interface.fetch decoder,
    predictor_fetch_interface.fetch predictor,
    CSR_ROB_fetch_interface.fetch CSR,
    cache_TLB_interface.cache TLB,
    flush_pipeline_interface.pipeline flush_pipeline
);
    reg working;
    data_t req_pc;
    wire flush = predictor.flush || flush_pipeline.flush, flush_all = flush_pipeline.flush;

    reg [7:0] inst_running_cnt;
    wire inst_que_full;

    request_interface mem_write_req[2] ();
    data_transfer_interface mem_write_data[2] ();
    cache #(32) icache (
        .clk(clk),
        .rst(rst),
        .mem_cache_read_req(memory_read_req[0]),
        .mem_cache_read_data(memory_read_data[0]),
        .mem_cache_write_req(mem_write_req[0]),
        .mem_cache_write_data(mem_write_data[0]),
        .mem_mmio_read_req(memory_read_req[1]),
        .mem_mmio_read_data(memory_read_data[1]),
        .mem_mmio_write_req(mem_write_req[1]),
        .mem_mmio_write_data(mem_write_data[1]),
        .req_valid(working && ~flush),
        .req_virt_addr(req_pc),
        .req_info(req_pc),
        .req_is_write(0),
        .resp_ready(~inst_que_full),
        .TLB(TLB),
        .flush(flush || TLB.cacop_valid),
        .is_last_in_pipeline(inst_running_cnt==0)// 取指的mmio状态，指令执行状态判断有问题，不过目前不会向外设取指
    );
    always @(posedge clk) begin
        if (rst || flush_all) inst_running_cnt <= 0;
        else inst_running_cnt <= inst_running_cnt + (icache.resp_valid && icache.resp_ready) - (CSR.retire_valid);
    end

    typedef struct packed {
        data_t inst;
        data_t pc;
        exception_t exception;
    } inst_data_t;
    fifo #(4, $bits(
        inst_data_t
    )) inst_que (
        .clk(clk),
        .rst(rst || flush_all),
        .push(icache.resp_valid),
        .push_data({icache.resp_data, icache.resp_info, icache.resp_exception}),
        .pop(decoder.valid && decoder.allowin)
    );
    assign inst_que_full = inst_que.full;
    always @(posedge clk) begin
        if (rst) working <= 1;
        else if (CSR.target_valid) working <= 1;
        else if (CSR.target_valid2) working <= 1;
        else if (predictor.target_valid) working <= 1;
        else if (flush) working <= 0;
        else if (icache.resp_valid && icache.resp_exception != EXCEPTION_NONE) working <= 0;
    end
    always @(posedge clk) begin
        if (rst) req_pc <= 'h1C000000;
        else if (CSR.target_valid) req_pc <= CSR.target_pc;
        else if (CSR.target_valid2) req_pc <= CSR.target_pc2;
        else if (predictor.target_valid) req_pc <= predictor.target_pc;
        else if (working && icache.req_ready) req_pc <= req_pc + 4;
    end

    wire inst_data_t inst_data = inst_que.pop_data;
    assign decoder.valid = ~inst_que.empty && ~flush_all;
    assign decoder.pc = inst_data.pc;
    assign decoder.inst = inst_data.inst;
    assign decoder.exception = inst_data.exception;

    assign predictor.inst_valid = icache.resp_valid && icache.resp_exception == EXCEPTION_NONE;
    assign predictor.inst = icache.resp_data;
    assign predictor.inst_pc = icache.resp_info;

endmodule

`default_nettype wire
