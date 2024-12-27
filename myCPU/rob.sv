

`include "common.svh"

`default_nettype none

interface commit_rob_interface;
    logic valid, allowin;
    assign allowin = 1;
    rob_id_t rob_id;
    phy_addr_t rd_phy;
    data_t rd_data;
    modport commit(output valid, input allowin, output rob_id, rd_phy, rd_data);
    modport ROB(input valid, input rob_id, rd_data);
endinterface

interface exception_throw_interface;
    logic valid;
    rob_id_t rob_id;
    exception_t exception;
    modport execute(output valid, rob_id, exception);
    modport ROB(input valid, rob_id, exception);
endinterface

module reorder_buffer (
    input wire clk,
    input wire rst,

    decode_rename_rob_dispatch_interface.ROB decoder,
    rob_rename_interface.ROB rename,
    commit_rob_interface.ROB eu[4],
    exception_throw_interface.ROB exception_raise[2],
    flush_pipeline_interface.ROB flush_send,
    CSR_ROB_interface.ROB CSR,
    CSR_ROB_fetch_interface.ROB fetch,

    output rob_id_t next_retire_inst_id,
    output wire [69:0] inst_reitre_tb
);
    typedef struct packed {
        data_t pc;
        arch_addr_t rd_arch;  // this instruction arch waddr
        phy_addr_t rd_origin;  // the phy reg can be released
        phy_addr_t rd_phy;  // this instruction phy waddr
    } rob_inst_info_t;

    reg [63:0] inst_ready;
    data_t [63:0] inst_rd_data;
    reg [63:0] inst_exception_from_pc;
    exception_t [63:0] inst_exception;
    reg [63:0] inst_interrupt;

    wire flush;
    wire retire_ready;
    wire [5:0] retire_addr;
    rob_inst_info_t retire_info;

    fifo #(6, $bits(
        rob_inst_info_t
    )) inst_info (
        .clk(clk),
        .rst(rst | flush),
        .push(decoder.valid),
        .push_data({decoder.pc, decoder.rd_arch, decoder.rd_origin, decoder.rd_phy}),
        .pop(retire_ready)
    );

    assign retire_ready = ~inst_info.empty && inst_ready[retire_addr];  // note: valid though flush，否则队列pop不掉
    assign retire_addr = inst_info.rd_ptr;
    assign retire_info = inst_info.pop_data;

    generate
        wire [3:0] valid_eus;
        wire [3:0][5:0] valid_rob_ids;
        wire [3:0][31:0] valid_rob_data;

        for (genvar i = 0; i < 4; i = i + 1) begin
            assign valid_eus[i]      = eu[i].valid;
            assign valid_rob_ids[i]  = eu[i].rob_id[5:0];
            assign valid_rob_data[i] = eu[i].rd_data;
        end
    endgenerate

    always @(posedge clk) begin
        if (decoder.valid) inst_ready[inst_info.wr_ptr[5:0]] <= 0;
        for (int i = 0; i < 4; i++) begin
            if (valid_eus[i]) inst_ready[valid_rob_ids[i]] <= 1;
        end
    end
    always @(posedge clk) begin
        for (integer i = 0; i < 4; i = i + 1) begin
            if (valid_eus[i]) begin
                inst_rd_data[valid_rob_ids[i]] <= valid_rob_data[i];
            end
        end
    end
    always @(posedge clk) begin
        if (decoder.valid) inst_exception[inst_info.wr_ptr[5:0]] <= decoder.exception;
        if (decoder.valid) inst_exception_from_pc[inst_info.wr_ptr[5:0]] <= decoder.exception != EXCEPTION_NONE;
        if (exception_raise[0].valid) inst_exception[exception_raise[0].rob_id[5:0]] <= exception_raise[0].exception;
        if (exception_raise[0].valid) inst_exception_from_pc[exception_raise[0].rob_id[5:0]] <= 0;
        if (exception_raise[1].valid) inst_exception[exception_raise[1].rob_id[5:0]] <= exception_raise[1].exception;
        if (exception_raise[1].valid) inst_exception_from_pc[exception_raise[1].rob_id[5:0]] <= 0;

        if (CSR.log_interrupt_in_rob) inst_interrupt[inst_info.wr_ptr[5:0]] <= 1;
        else if (decoder.valid) inst_interrupt[inst_info.wr_ptr[5:0]] <= 0;
    end

    reg [1:0] flushpipeline_state;// 退休一条指令后就flush，需要CSR保证拉高flush_pipeline信号时，它是最后一条指令
    wire flush_pipeline = flushpipeline_state == 2;
    always @(posedge clk) begin
        if (rst | flush) flushpipeline_state <= 0;
        else
            case (flushpipeline_state)
                0: if (CSR.flush_pipeline_tag_valid) flushpipeline_state <= 1;
                1: if (retire_ready) flushpipeline_state <= 2;
                2: flushpipeline_state <= 0;
                default: flushpipeline_state <= 0;
            endcase
    end
    assign next_retire_inst_id = inst_info.rd_ptr;
    // 有个潜在的问题，interrupt指令retire时，已经执行了，比如CSR/MEM指令，不过目前没有interrupt
    assign flush = ~inst_info.empty && (inst_exception[retire_addr] != EXCEPTION_NONE || inst_interrupt[retire_addr]) || flush_pipeline;

    assign decoder.rob_ready = ~inst_info.full;
    assign decoder.rob_id = inst_info.wr_ptr;
    assign rename.free_valid = retire_ready && ~flush;
    assign rename.rd_phy = retire_info.rd_phy;
    assign rename.rd_origin = retire_info.rd_origin;
    assign rename.rd_arch = retire_info.rd_arch;
    assign flush_send.is_exception = flush;
    assign CSR.raise_exception = flush && ~flush_pipeline;
    assign CSR.exception = inst_interrupt[retire_addr] ? EXCEPTION_INTERRUPT : inst_exception[retire_addr];
    assign CSR.exception_from_pc = inst_exception_from_pc[retire_addr];
    assign CSR.PC = retire_info.pc;
    assign fetch.retire_valid = retire_ready;
    assign fetch.target_valid2 = flush_pipeline;
    always @(posedge clk) begin
        if (flushpipeline_state == 1 && retire_ready) fetch.target_pc2 <= retire_info.pc + 4;
    end


    assign inst_reitre_tb = {
        rename.free_valid && |retire_info.rd_phy, retire_info.rd_arch, inst_rd_data[retire_addr], retire_info.pc
    };
    data_t retire_pc;
    always @(posedge clk) begin
        if (~inst_info.empty) retire_pc <= retire_info.pc;
    end
endmodule

`default_nettype wire
