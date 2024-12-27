

`include "common.svh"
`default_nettype none

module predict_unit (
    input wire clk,
    input wire rst,

    predictor_fetch_interface.predictor fetch,
    bru_predictor_interface.predictor   bru
);
    logic  inst_valid;
    data_t inst;
    always @(posedge clk) begin
        inst_valid <= fetch.inst_valid;
        inst <= fetch.inst;
    end
    wire is_branch;
    decode_branch_loongarch BQD (
        .inst(inst),
        .is_branch(is_branch)
    );
    assign fetch.flush = inst_valid && is_branch;
    assign fetch.target_valid = bru.valid;
    assign fetch.target_pc = bru.branch_taken ? bru.branch_target : bru.inst_pc + 4;
endmodule

`default_nettype wire
