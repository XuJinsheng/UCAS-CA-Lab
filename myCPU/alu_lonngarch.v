// this file is the implementation of the logic part of the ALU, MDU and BRU modules


module alu_lonngarch #(
    parameter logical_operator = 1,
    parameter shift_operator = 1,
    parameter DATA_WIDTH = 32
) (
    input  wire [DATA_WIDTH-1:0] A,
    input  wire [DATA_WIDTH-1:0] B,
    input  wire [           3:0] ALUop,
    output wire                  Overflow,
    output wire                  CarryOut,
    output wire                  Zero,
    output wire [DATA_WIDTH-1:0] Result
);
    parameter OP_ADD=4'b0000,OP_SUB=4'b0001,OP_SLT=4'b0010,OP_SLTU=4'b0011,OP_SLL=4'b0100,OP_SRL=4'b0101,OP_SRA=4'b0110,OP_XOR=4'b1000,OP_OR=4'b1001,OP_NOR=4'b1010,OP_AND=4'b1011;
    wire opADD, opSUB, opSLT, opSLTU, opSLL, opSRL, opSRA, opXOR, opOR, opNOR, opAND;
    assign opADD = ALUop == OP_ADD,
        opSUB = ALUop == OP_SUB,
        opSLT = ALUop == OP_SLT,
        opSLTU = ALUop == OP_SLTU,
        opSLL = ALUop == OP_SLL,
        opSRL = ALUop == OP_SRL,
        opSRA = ALUop == OP_SRA,
        opXOR = ALUop == OP_XOR,
        opOR = ALUop == OP_OR,
        opNOR = ALUop == OP_NOR,
        opAND = ALUop == OP_AND;

    wire cout, cin;
    wire [DATA_WIDTH-1:0] S;
    wire [DATA_WIDTH-1:0] b;
    assign {cout, S} = A + b + cin;

    /* (opSUB || opSLT || opSLTU) = ~opADD = |ALUop
	assign cin = (opSUB || opSLT || opSLTU) ? 1 : 0;
	assign b = (opSUB || opSLT || opSLTU) ? ~B : B; */
    assign cin = (|ALUop) ? 1 : 0;
    assign b = (|ALUop) ? ~B : B;

    assign Overflow=(A[DATA_WIDTH - 1]&&b[DATA_WIDTH - 1]&&~S[DATA_WIDTH - 1])
	   				||(~A[DATA_WIDTH - 1]&&~b[DATA_WIDTH - 1]&&S[DATA_WIDTH - 1]);
    assign CarryOut = (opADD & cout) || (opSUB & ~cout);
    assign Zero = ~|Result;

    wire [DATA_WIDTH-1:0] logical_result, shift_result;
    generate
        if (logical_operator)
            assign logical_result
				={DATA_WIDTH{opXOR}}&	(A^B)|
				{DATA_WIDTH{opOR}}&		(A|B)|
				{DATA_WIDTH{opNOR}}&	~(A|B)|
				{DATA_WIDTH{opAND}}&	(A&B);
        else assign logical_result = 0;
        wire [DATA_WIDTH-1:0] sra_S = $signed(A) >>> B[4:0];
        if (shift_operator)
            assign  shift_result
				={DATA_WIDTH{opSLL}}&	(A<<B[4:0])|
				{DATA_WIDTH{opSRL}}&	(A>>B[4:0])|
				{DATA_WIDTH{opSRA}}&	sra_S;
        else assign shift_result = 0;
    endgenerate
    assign Result=(
		{DATA_WIDTH{opADD|opSUB}}&	S|
		{DATA_WIDTH{opSLT}}&		((A[DATA_WIDTH - 1]^B[DATA_WIDTH - 1]^~cout)?1:0)|
		{DATA_WIDTH{opSLTU}}&		((~cout)?1:0)|
		logical_result|shift_result
	);
endmodule

module mdu_lonngarch (
    input wire clk,
    input wire rst,
    input wire input_valid,
    output reg output_ready,
    input wire [31:0] A,
    input wire [31:0] B,
    input wire [2:0] MDUop,
    output reg [31:0] Result
);
    parameter OP_MUL=3'b000,OP_MULH=3'b001,OP_MULHU=3'b010,OP_DIV=3'b100,OP_MOD=3'b101,OP_DIVU=3'b110,OP_MODU=3'b111;
    wire is_div = MDUop[2], is_div_unsigned = MDUop[1];
    wire [63:0] mul_result = A * B, mulsigned_result = $signed(A) * $signed(B);
    wire [31:0] div_result, mod_result, divu_result, modu_result;


    wire div_signed_in_ready, div_unsigned_in_ready, div_signed_out_valid, div_unsigned_out_valid;
    wire div_in_ready = is_div_unsigned ? div_unsigned_in_ready : div_signed_in_ready;
    wire div_out_valid = is_div_unsigned ? div_unsigned_out_valid : div_signed_out_valid;

    parameter S_WAIT = 0, S_MUL = 1, S_DIV_WAIT = 2, S_DIV = 3;
    reg [3:0] state, next_state;
    reg [1:0] mul_countdown;
    always @(posedge clk) begin
        if (rst) state <= 1 << S_WAIT;
        else state <= next_state;
    end
    always @(posedge clk) begin
        if (state[S_MUL]) mul_countdown <= mul_countdown == 0 ? 0 : mul_countdown - 1;
        else if (input_valid) mul_countdown <= 1;  // TODO: a better condition priority is needed
    end
    wire finished = state[S_MUL] && mul_countdown == 0 || state[S_DIV] && div_out_valid;
    always @(*) begin
        case (state)
            1 << S_WAIT:
            if (input_valid && is_div) next_state = 1 << S_DIV_WAIT;
            else if (input_valid && !is_div) next_state = 1 << S_MUL;
            else next_state = 1 << S_WAIT;
            1 << S_MUL: next_state = finished ? 1 << S_WAIT : 1 << S_MUL;
            1 << S_DIV_WAIT: next_state = div_in_ready ? 1 << S_DIV : 1 << S_DIV_WAIT;
            1 << S_DIV: next_state = finished ? 1 << S_WAIT : 1 << S_DIV;
            default: next_state = 1 << S_WAIT;
        endcase
    end
    always @(posedge clk) begin
        output_ready <= finished;
        if (finished)
            case (MDUop)
                OP_MUL:   Result <= mul_result[31:0];
                OP_MULH:  Result <= mulsigned_result[63:32];
                OP_MULHU: Result <= mul_result[63:32];
                OP_DIV:   Result <= div_result;
                OP_MOD:   Result <= mod_result;
                OP_DIVU:  Result <= divu_result;
                OP_MODU:  Result <= modu_result;
            endcase
    end

    div_gen_signed div_signed (
        .aclk(clk),
        .s_axis_divisor_tvalid(state[S_DIV_WAIT] && !is_div_unsigned),
        .s_axis_divisor_tready(div_signed_in_ready),
        .s_axis_divisor_tdata(B),
        .s_axis_dividend_tvalid(state[S_DIV_WAIT] && !is_div_unsigned),
        .s_axis_dividend_tready(),
        .s_axis_dividend_tdata(A),
        .m_axis_dout_tvalid(div_signed_out_valid),
        .m_axis_dout_tdata({div_result, mod_result})
    );
    div_gen_unsigned div_unsigned (
        .aclk(clk),
        .s_axis_divisor_tvalid(state[S_DIV_WAIT] && is_div_unsigned),
        .s_axis_divisor_tready(div_unsigned_in_ready),
        .s_axis_divisor_tdata(B),
        .s_axis_dividend_tvalid(state[S_DIV_WAIT] && is_div_unsigned),
        .s_axis_dividend_tready(),
        .s_axis_dividend_tdata(A),
        .m_axis_dout_tvalid(div_unsigned_out_valid),
        .m_axis_dout_tdata({divu_result, modu_result})
    );
endmodule


module branch_loongarch (
    input wire [3:0] uop,
    input wire [31:0] rs1,
    input wire [31:0] rs2,
    input wire [31:0] immediate,
    input wire [31:0] PC,
    output wire uop_is_branch,
    output reg branch_taken,
    output wire [31:0] branch_target,
    output wire [31:0] rd_data
);
    parameter OP_BEQZ = 4'b000, OP_BNEZ = 4'b001, OP_BEQ = 4'b010, OP_BNE = 4'b011, OP_BLT = 4'b100, OP_BGE = 4'b101, OP_BLTU = 4'b110, OP_BGEU = 4'b111;
    parameter OP_JAL = 4'b1000, OP_JALR = 4'b1001, OP_AUIPC = 4'b1010, OP_LUI = 4'b1011;
    wire is_branch = ~uop[3];
    wire is_jal = uop == OP_JAL, is_jalr = uop == OP_JALR, is_auipc = uop == OP_AUIPC, is_lui = uop == OP_LUI;
    assign uop_is_branch = is_branch | is_jal | is_jalr;

    wire rs1_zero = ~|rs1, rs1_eq_rs2 = rs1 == rs2;
    wire unsigned_compare = uop[1];
    wire less_result;
    alu_lonngarch alu (
        .A(rs1),
        .B(rs2),
        .ALUop(unsigned_compare ? alu.OP_SLTU : alu.OP_SLT),
        .Result(less_result)
    );
    always @(*) begin
        case (uop)
            OP_BEQZ: branch_taken = rs1_zero;
            OP_BNEZ: branch_taken = ~rs1_zero;
            OP_BEQ:  branch_taken = rs1_eq_rs2;
            OP_BNE:  branch_taken = ~rs1_eq_rs2;
            OP_BLT:  branch_taken = less_result;
            OP_BGE:  branch_taken = ~less_result;
            OP_BLTU: branch_taken = less_result;
            OP_BGEU: branch_taken = ~less_result;
            OP_JAL:  branch_taken = 1;
            OP_JALR: branch_taken = 1;
            default: branch_taken = 0;
        endcase
    end
    wire [31:0] PCa4 = PC + 4, PCoffset = (is_jalr ? rs1 : PC) + immediate;
    assign branch_target = PCoffset;
    assign rd_data = is_lui ? immediate : is_auipc ? PCoffset : PCa4;

endmodule
