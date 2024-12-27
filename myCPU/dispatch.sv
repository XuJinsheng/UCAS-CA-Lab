`include "common.svh"

interface dispatch_issue_interface;
    logic valid, allowin;

    uop_t uop;
    rob_id_t rob_id;
    data_t pc;
    immediate_t immediate;
    phy_addr_t rs1_phy, rs2_phy, rd_phy;
    logic rs1_ready, rs2_ready;
    modport dispatch(
        output valid,
        input allowin,
        output uop, rob_id, pc, immediate, rs1_phy, rs2_phy, rd_phy, rs1_ready, rs2_ready
    );
    modport issue(
        input valid,
        output allowin,
        input uop, rob_id, pc, immediate, rs1_phy, rs2_phy, rd_phy, rs1_ready, rs2_ready
    );
endinterface


interface issue_execute_interface;
    logic valid, allowin;

    eu_inst_info inst_id;
    uop_t uop;
    data_t pc;
    data_t rs1_data, rs2_data;
    immediate_t immediate;

    modport issue(output valid, input allowin, output inst_id, uop, pc, rs1_data, rs2_data, immediate);
    modport execute(input valid, output allowin, input inst_id, uop, pc, rs1_data, rs2_data, immediate);
endinterface


interface execute_commit_interface;
    logic valid, allowin;
    eu_inst_info inst_id;
    data_t rd_data;
    modport execute(output valid, input allowin, output inst_id, rd_data);

    rob_id_t rob_id;
    assign rob_id = inst_id.rob_id;
    phy_addr_t rd_phy;
    assign rd_phy = inst_id.rd_phy;
    modport bypass(input valid, rd_phy, rd_data);
    modport commit(input valid, output allowin, input rob_id, rd_phy, rd_data);
endinterface


interface wakeup_interface;
    logic valid;
    phy_addr_t rd_phy;
    modport send(output valid, rd_phy);
    modport receive(input valid, rd_phy);
endinterface


module dispatch_unit (
    input wire clk,
    input wire rst,

    data_read_interface.read readytable_read[10],
    decode_rename_rob_dispatch_interface.dispatch decoder,
    dispatch_issue_interface.dispatch issue[5],
    flush_pipeline_interface.pipeline flush_pipeline,
    input wire rob_id_t next_retire_inst_id
);
    typedef struct packed {
        logic [6:0] futype;
        data_t pc;
        uop_t uop;
        immediate_t immediate;
        rob_id_t rob_id;
        phy_addr_t rs1_phy, rs2_phy, rd_phy;
    } dispatch_info;

    wire [4:0] issue_allowin, issue_valid;
    dispatch_info issue_inst;

    fifo #(4, $bits(
        dispatch_info
    )) dispatch_fifo (
        .clk(clk),
        .rst(rst | flush_pipeline.flush),
        .push(decoder.valid),
        .push_data({
            decoder.futype,
            decoder.pc,
            decoder.uop,
            decoder.immediate,
            decoder.rob_id,
            decoder.rs1_phy,
            decoder.rs2_phy,
            decoder.rd_phy
        }),
        .pop(|(issue_allowin & issue_valid))
    );

    reg last_is_csr;
    rob_id_t last_inst_rob_id;
    wire now_is_csr = issue_inst.futype[4];
    always @(posedge clk) begin
        if (rst | flush_pipeline.flush) last_is_csr <= 0;
        else if (|(issue_allowin & issue_valid)) begin
            last_is_csr <= now_is_csr;
            last_inst_rob_id <= issue_inst.rob_id;
        end
    end
    wire wait_for_csr_inst=now_is_csr&&issue_inst.rob_id!=next_retire_inst_id||last_is_csr&&last_inst_rob_id==next_retire_inst_id;

    assign decoder.dispatch_ready = ~dispatch_fifo.full;
    assign issue_inst = dispatch_fifo.pop_data;
    assign issue_valid = (~dispatch_fifo.empty && ~flush_pipeline.flush && ~wait_for_csr_inst) ? issue_inst.futype : 0;
    wire rs1_ready, rs2_ready;
    generate
        for (genvar i = 0; i < 5; i++) begin
            assign issue_allowin[i] = issue[i].allowin;
            assign issue[i].valid = issue_valid[i];
            assign issue[i].uop = issue_inst.uop;
            assign issue[i].pc = issue_inst.pc;
            assign issue[i].rob_id = issue_inst.rob_id;
            assign issue[i].immediate = issue_inst.immediate;
            assign issue[i].rs1_phy = issue_inst.rs1_phy;
            assign issue[i].rs2_phy = issue_inst.rs2_phy;
            assign issue[i].rd_phy = issue_inst.rd_phy;
            assign issue[i].rs1_ready = rs1_ready;
            assign issue[i].rs2_ready = rs2_ready;
        end
    endgenerate

    assign readytable_read[0].addr = issue_inst.rs1_phy;
    assign rs1_ready = readytable_read[0].data;
    assign readytable_read[1].addr = issue_inst.rs2_phy;
    assign rs2_ready = readytable_read[1].data;
endmodule

/*
发射-唤醒时序
找出要发射的指令，同时从wakeup里进行比较唤醒（eu出来的rd_phy和valid必须clk之后就给出）
发射的指令在cluster里进行广播，同时在regfile里进行读取
*/
module issue_cluster (
    input wire clk,
    input wire rst,

    data_read_interface.read regfile_read[2],
    dispatch_issue_interface.issue dispatch,
    issue_execute_interface.issue execute,
    execute_commit_interface.bypass bypass,
    wakeup_interface.receive wakeup_receive[4],
    flush_pipeline_interface.pipeline flush_pipeline
);
    uop_t uop;
    eu_inst_info inst_id;
    immediate_t immediate;
    phy_addr_t rs1_phy, rs2_phy;
    logic rs1_ready, rs2_ready;
    data_t pc;
    pipeline_stage_wire pipeline (
        .clk(clk),
        .rst(rst),
        .input_valid(dispatch.valid),
        .this_allowin(dispatch.allowin),
        .output_valid(execute.valid),
        .next_allowin(execute.allowin),
        .ready_go(rs1_ready && rs2_ready || flush_pipeline.flush),
        .flush(flush_pipeline.flush)
    );
    wire [3:0] rs1_wakeup_wire, rs2_wakeup_wire;
    wire [3:0] dispatch_rs1_wakeup_wire, dispatch_rs2_wakeup_wire;
    generate
        for (genvar i = 0; i < 4; i++) begin
            assign rs1_wakeup_wire[i] = wakeup_receive[i].valid && wakeup_receive[i].rd_phy == rs1_phy;
            assign rs2_wakeup_wire[i] = wakeup_receive[i].valid && wakeup_receive[i].rd_phy == rs2_phy;
            assign dispatch_rs1_wakeup_wire[i] = wakeup_receive[i].valid && wakeup_receive[i].rd_phy == dispatch.rs1_phy;
            assign dispatch_rs2_wakeup_wire[i] = wakeup_receive[i].valid && wakeup_receive[i].rd_phy == dispatch.rs2_phy;
        end
    endgenerate
    always @(posedge clk) begin
        if (pipeline.input_next) begin
            inst_id <= '{dispatch.rob_id, dispatch.rd_phy};
            uop <= dispatch.uop;
            pc <= dispatch.pc;
            immediate <= dispatch.immediate;
            rs1_phy <= dispatch.rs1_phy;
            rs2_phy <= dispatch.rs2_phy;
            rs1_ready <= dispatch.rs1_ready || dispatch_rs1_wakeup_wire;
            rs2_ready <= dispatch.rs2_ready || dispatch_rs2_wakeup_wire;
        end else begin
            if (|rs1_wakeup_wire) rs1_ready <= 1;
            if (|rs2_wakeup_wire) rs2_ready <= 1;
        end
    end
    assign regfile_read[0].addr = rs1_phy;
    assign execute.rs1_data = regfile_read[0].data;
    assign regfile_read[1].addr = rs2_phy;
    assign execute.rs2_data = regfile_read[1].data;
    assign execute.uop = uop;
    assign execute.inst_id = inst_id;
    assign execute.immediate = immediate;
    assign execute.pc = pc;
endmodule



module commit_unit (
    input wire clk,
    input wire rst,


    data_write_interface.write regfile_write,
    data_write_interface.write readytable_write,
    execute_commit_interface.commit execute,
    commit_rob_interface.commit ROB,
    wakeup_interface.send wakeup_send
);
    assign execute.allowin = 1;
    assign regfile_write.wen = execute.valid;
    assign regfile_write.addr = execute.rd_phy;
    assign regfile_write.data = execute.rd_data;
    assign readytable_write.wen = execute.valid;
    assign readytable_write.addr = execute.rd_phy;
    assign readytable_write.data = 1;
    assign ROB.valid = execute.valid;
    assign ROB.rob_id = execute.rob_id;
    assign ROB.rd_phy = execute.rd_phy;
    assign ROB.rd_data = execute.rd_data;
    assign wakeup_send.valid = execute.valid;
    assign wakeup_send.rd_phy = execute.rd_phy;
endmodule

module commit_unit2 (
    input wire clk,
    input wire rst,

    data_write_interface.write regfile_write,
    data_write_interface.write readytable_write,
    execute_commit_interface.commit execute0,
    execute_commit_interface.commit execute1,
    commit_rob_interface.commit ROB,
    wakeup_interface.send wakeup_send
);
    assign execute0.allowin = 1;
    assign execute1.allowin = ~execute0.valid;
    logic valid;
    phy_addr_t rd_phy;
    data_t rd_data;
    rob_id_t rob_id;
    always_comb begin
        if (execute0.valid) begin
            valid   = execute0.valid;
            rd_phy  = execute0.rd_phy;
            rd_data = execute0.rd_data;
            rob_id  = execute0.rob_id;
        end else begin
            valid   = execute1.valid;
            rd_phy  = execute1.rd_phy;
            rd_data = execute1.rd_data;
            rob_id  = execute1.rob_id;
        end
    end
    assign regfile_write.wen = valid;
    assign regfile_write.addr = rd_phy;
    assign regfile_write.data = rd_data;
    assign readytable_write.wen = valid;
    assign readytable_write.addr = rd_phy;
    assign readytable_write.data = 1;
    assign ROB.valid = valid;
    assign ROB.rob_id = rob_id;
    assign ROB.rd_phy = rd_phy;
    assign ROB.rd_data = rd_data;
    assign wakeup_send.valid = valid;
    assign wakeup_send.rd_phy = rd_phy;
endmodule
