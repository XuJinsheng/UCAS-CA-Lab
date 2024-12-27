`include "common.svh"

interface decode_rename_rob_dispatch_interface;
    data_t pc;

    logic rs1_en, rs2_en, rd_en;
    arch_addr_t rs1_arch, rs2_arch, rd_arch;
    phy_addr_t rs1_phy, rs2_phy, rd_phy, rd_origin;

    rob_id_t rob_id;
    immediate_t immediate;
    uop_t uop;
    logic [6:0] futype;  // 0: alu, 1: mdu, 2: branch, 3: load/store, 4: CSR, 5: MISC
    exception_t exception;

    logic valid;
    logic next_ready, rob_ready, dispatch_ready, rename_ready;
    assign next_ready = rob_ready && dispatch_ready && rename_ready;
    modport decode(
        input next_ready,
        output valid, futype, uop, pc, immediate, exception,
        output rs1_en, rs2_en, rd_en, rs1_arch, rs2_arch, rd_arch
    );
    modport rename(
        output rename_ready,
        input valid, rd_en, rs1_arch, rs2_arch, rd_arch,
        output rs1_phy, rs2_phy, rd_phy, rd_origin
    );
    modport ROB(output rob_ready, rob_id, input valid, pc, rd_arch, rd_phy, rd_origin, exception);
    modport dispatch(
        output dispatch_ready,
        input valid, futype, uop, immediate, pc,
        input rob_id, rs1_phy, rs2_phy, rd_phy
    );
endinterface

module decode_unit (
    input wire clk,
    input wire rst,

    fetch_decode_interface.decode ifetch,
    decode_rename_rob_dispatch_interface.decode dispatch,
    flush_pipeline_interface.pipeline flush_pipeline
);
    pipeline_stage_wire pipeline (
        .clk(clk),
        .rst(rst),
        .input_valid(ifetch.valid),
        .this_allowin(ifetch.allowin),
        .next_allowin(1),
        .ready_go(dispatch.next_ready),
        .flush(flush_pipeline.flush)
    );
    //	这一周期rename之后，下一周期才反映出队列是否满，但这时东西已经进来了，同时走的时候再把对rename/rob的信号拉高，让他们进移动队列指针
    reg [31:0] Inst, pc;
    exception_t exception;
    always @(posedge clk) begin
        if (pipeline.input_next) begin
            Inst <= ifetch.exception != EXCEPTION_NONE ? 0 : ifetch.inst;
            pc <= ifetch.pc;
            exception <= ifetch.exception;
        end
    end

    assign dispatch.pc = pc;
    assign dispatch.valid = pipeline.output_go;

    wire [6:0] futype;
    wire [5:0] uop;
    wire [4:0] rs1_addr;
    wire [4:0] rs2_addr;
    wire [4:0] rd_addr;
    wire rs1_en;
    wire rs2_en;
    wire rd_en;
    wire [31:0] immediate;

    decode_loongarch decode (
        .inst(Inst),
        .futype(futype),
        .uop(uop),
        .rs1_addr(rs1_addr),
        .rs2_addr(rs2_addr),
        .rd_addr(rd_addr),
        .rs1_en(rs1_en),
        .rs2_en(rs2_en),
        .rd_en(rd_en),
        .immediate(immediate),
        .fetch_exception(exception),
        .exception(dispatch.exception)
    );
    assign dispatch.futype = futype;
    assign dispatch.uop = uop;
    assign dispatch.rs1_arch = rs1_addr;
    assign dispatch.rs2_arch = rs2_addr;
    assign dispatch.rd_arch = rd_addr;
    assign dispatch.rs1_en = rs1_en;
    assign dispatch.rs2_en = rs2_en;
    assign dispatch.rd_en = rd_en;
    assign dispatch.immediate = immediate;

endmodule

