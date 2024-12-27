

`include "common.svh"
`default_nettype none


interface bru_predictor_interface;
    logic  valid;
    data_t inst_pc;
    logic  branch_taken;
    data_t branch_target;
    modport BRU(output valid, inst_pc, branch_taken, branch_target);
    modport predictor(input valid, inst_pc, branch_taken, branch_target);
endinterface

module branch_unit (
    input wire clk,
    input wire rst,

    issue_execute_interface.execute in,
    execute_commit_interface.execute out,
    flush_pipeline_interface.pipeline flush_pipeline,
    bru_predictor_interface.BRU predictor
);
    eu_inst_info inst_id;
    data_t rs1, rs2;
    data_t PC;
    immediate_t immediate;
    reg [3:0] funct;
    pipeline_stage_wire pipeline (
        .clk(clk),
        .rst(rst),
        .input_valid(in.valid),
        .this_allowin(in.allowin),
        .output_valid(out.valid),
        .next_allowin(out.allowin),
        .ready_go(1),
        .flush(flush_pipeline.flush)
    );
    always @(posedge clk) begin
        if (pipeline.input_next) begin
            inst_id <= in.inst_id;
            rs1 <= in.rs1_data;
            rs2 <= in.rs2_data;
            immediate <= in.immediate;
            PC <= in.pc;
            funct <= in.uop;
        end
    end
    wire inst_is_branch, branch_taken;
    data_t branch_target, rd_data;

    branch_loongarch bru (
        .uop(funct),
        .rs1(rs1),
        .rs2(rs2),
        .immediate(immediate),
        .PC(PC),
        .uop_is_branch(inst_is_branch),
        .branch_taken(branch_taken),
        .branch_target(branch_target),
        .rd_data(rd_data)
    );
    assign out.inst_id = inst_id;
    assign out.rd_data = rd_data;

    assign predictor.valid = pipeline.output_go && inst_is_branch;
    assign predictor.inst_pc = PC;
    assign predictor.branch_taken = branch_taken;
    assign predictor.branch_target = branch_target;
endmodule



/*uop for alu
	[5] data2 from 1:immediate, 0:rs2_data
	[3:0] alu_op
*/
module alu_unit (
    input wire clk,
    input wire rst,

    issue_execute_interface.execute   in,
    execute_commit_interface.execute  out,
    flush_pipeline_interface.pipeline flush_pipeline
);
    eu_inst_info inst_id;
    data_t rs1, rs2;
    immediate_t immediate;
    reg [3:0] aluop;
    reg is_imm;
    pipeline_stage_wire pipeline (
        .clk(clk),
        .rst(rst),
        .input_valid(in.valid),
        .this_allowin(in.allowin),
        .output_valid(out.valid),
        .next_allowin(out.allowin),
        .ready_go(1),
        .flush(flush_pipeline.flush)
    );
    always @(posedge clk) begin
        if (pipeline.input_next) begin
            inst_id <= in.inst_id;
            rs1 <= in.rs1_data;
            rs2 <= in.rs2_data;
            immediate <= in.immediate;
            aluop <= in.uop[3:0];
            is_imm <= in.uop[5];
        end
    end
    wire data_t A = rs1, B = is_imm ? immediate : rs2;
    wire data_t alu_res;
    alu_lonngarch alu (
        .A     (A),
        .B     (B),
        .ALUop (aluop),
        .Result(alu_res)
    );
    assign out.inst_id = inst_id;
    assign out.rd_data = alu_res;
endmodule

module muldiv_unit (
    input wire clk,
    input wire rst,

    issue_execute_interface.execute   in,
    execute_commit_interface.execute  out,
    flush_pipeline_interface.pipeline flush_pipeline

);
    eu_inst_info inst_id;
    data_t rs1, rs2;
    reg [2:0] funct;
    wire ready_go;
    pipeline_stage_wire pipeline (
        .clk(clk),
        .rst(rst),
        .input_valid(in.valid),
        .this_allowin(in.allowin),
        .output_valid(out.valid),
        .next_allowin(out.allowin),
        .ready_go(ready_go),
        .flush(flush_pipeline.flush)
    );
    always @(posedge clk) begin
        if (pipeline.input_next) begin
            inst_id <= in.inst_id;
            rs1 <= in.rs1_data;
            rs2 <= in.rs2_data;
            funct <= in.uop[2:0];
        end
    end
    wire data_t A = rs1, B = rs2;
    wire data_t mdu_res;
    mdu_lonngarch mdu (
        .clk(clk),
        .rst(rst),
        .input_valid(pipeline.working & ~ready_go),
        .output_ready(ready_go),
        .A(rs1),
        .B(rs2),
        .MDUop(funct),
        .Result(mdu_res)
    );
    assign out.inst_id = inst_id;
    assign out.rd_data = mdu_res;
endmodule
`default_nettype wire
