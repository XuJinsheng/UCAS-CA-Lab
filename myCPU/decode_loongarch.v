`timescale 10 ns / 1 ns

module decode_loongarch (
    input wire [31:0] inst,
    output wire [6:0] futype,  // 0: alu, 1: mdu, 2: branch, 3: load/store, 4: CSR, 5: MISC
    output wire [5:0] uop,
    output wire [4:0] rs1_addr,
    output wire [4:0] rs2_addr,
    output wire [4:0] rd_addr,
    output wire rs1_en,
    output wire rs2_en,
    output wire rd_en,
    output wire [31:0] immediate,
    input wire [4:0] fetch_exception,
    output wire [4:0] exception
);
    wire [ 5:0] op_31_26 = inst[31:26];
    wire [ 3:0] op_25_22 = inst[25:22];
    wire [ 1:0] op_21_20 = inst[21:20];
    wire [ 4:0] op_19_15 = inst[19:15];
    wire [ 4:0] op_14_10 = inst[14:10];
    wire [63:0] op_31_26_d;
    wire [15:0] op_25_22_d;
    wire [ 3:0] op_21_20_d;
    wire [31:0] op_19_15_d;
    wire [31:0] op_14_10_d;
    decoder_6_64 u_dec0 (
        .in (op_31_26),
        .out(op_31_26_d)
    );
    decoder_4_16 u_dec1 (
        .in (op_25_22),
        .out(op_25_22_d)
    );
    decoder_2_4 u_dec2 (
        .in (op_21_20),
        .out(op_21_20_d)
    );
    decoder_5_32 u_dec3 (
        .in (op_19_15),
        .out(op_19_15_d)
    );
    decoder_5_32 u_dec4 (
        .in (op_14_10),
        .out(op_14_10_d)
    );

    wire i_LUI12 = op_31_26_d[6'h05] & ~inst[25];
    wire i_AUIPC12 = op_31_26_d[6'h07] & ~inst[25];

    wire i_SLLI = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h01];
    wire i_SRLI = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h09];
    wire i_SRAI = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h11];
    wire i_SLTI = op_31_26_d[6'h00] & op_25_22_d[4'b1000];
    wire i_SLTUI = op_31_26_d[6'h00] & op_25_22_d[4'b1001];
    wire i_ADDI = op_31_26_d[6'h00] & op_25_22_d[4'b1010];
    wire i_ANDI = op_31_26_d[6'h00] & op_25_22_d[4'b1101];
    wire i_ORI = op_31_26_d[6'h00] & op_25_22_d[4'b1110];
    wire i_XORI = op_31_26_d[6'h00] & op_25_22_d[4'b1111];
    wire i_ADD = op_31_26_d[0] & op_25_22_d[0] & op_21_20_d[1] & op_19_15_d[5'b00000];
    wire i_SUB = op_31_26_d[0] & op_25_22_d[0] & op_21_20_d[1] & op_19_15_d[5'b00010];
    wire i_SLT = op_31_26_d[0] & op_25_22_d[0] & op_21_20_d[1] & op_19_15_d[5'b00100];
    wire i_SLTU = op_31_26_d[0] & op_25_22_d[0] & op_21_20_d[1] & op_19_15_d[5'b00101];
    wire i_NOR = op_31_26_d[0] & op_25_22_d[0] & op_21_20_d[1] & op_19_15_d[5'b01000];
    wire i_AND = op_31_26_d[0] & op_25_22_d[0] & op_21_20_d[1] & op_19_15_d[5'b01001];
    wire i_OR = op_31_26_d[0] & op_25_22_d[0] & op_21_20_d[1] & op_19_15_d[5'b01010];
    wire i_XOR = op_31_26_d[0] & op_25_22_d[0] & op_21_20_d[1] & op_19_15_d[5'b01011];
    wire i_SLL = op_31_26_d[0] & op_25_22_d[0] & op_21_20_d[1] & op_19_15_d[5'b01110];
    wire i_SRL = op_31_26_d[0] & op_25_22_d[0] & op_21_20_d[1] & op_19_15_d[5'b01111];
    wire i_SRA = op_31_26_d[0] & op_25_22_d[0] & op_21_20_d[1] & op_19_15_d[5'b10000];


    wire t_alu_i = i_SLLI || i_SRLI || i_SRAI || i_SLTI || i_SLTUI || i_ADDI || i_ANDI || i_ORI || i_XORI;
    wire t_alu_r = i_ADD || i_SUB || i_SLT || i_SLTU || i_NOR || i_AND || i_OR || i_XOR || i_SLL || i_SRL || i_SRA;
    wire [5:0] uop_alu = {
        t_alu_i | i_LUI12,
        1'b0,
        (i_ADD|i_ADDI| i_LUI12)?4'b0000:i_SUB?4'b0001:(i_SLT|i_SLTI)?4'b0010:(i_SLTU|i_SLTUI)?4'b0011:(i_SLL|i_SLLI)?4'b0100:(i_SRL|i_SRLI)?4'b0101:(i_SRA|i_SRAI)?4'b0110:(i_XOR|i_XORI)?4'b1000:(i_OR|i_ORI)?4'b1001:(i_NOR)?4'b1010:(i_AND|i_ANDI)?4'b1011:4'b0000
    };
    wire t_mdu_mul = inst[31:17] == 'b1110;
    wire t_mdu_div = inst[31:17] == 'b10000;
    wire [5:0] uop_mdu = {3'b0, t_mdu_div, inst[16:15]};

    wire t_load = op_31_26_d[6'h0a] & ~inst[24];
    wire t_store = op_31_26_d[6'h0a] & ~inst[25] & inst[24];
    wire [5:0] uop_load_store = {t_store, 2'b00, inst[25], inst[23:22]};


    wire i_JIRL = op_31_26_d[6'b010011];
    wire i_JB = op_31_26_d[6'b010100];
    wire i_JBL = op_31_26_d[6'b010101];
    wire i_BEQZ = op_31_26_d[6'b010000];
    wire i_BNEZ = op_31_26_d[6'b010001];
    wire i_BEQ = op_31_26_d[6'b010110];
    wire i_BNE = op_31_26_d[6'b010111];
    wire i_BLT = op_31_26_d[6'b011000];
    wire i_BGE = op_31_26_d[6'b011001];
    wire i_BLTU = op_31_26_d[6'b011010];
    wire i_BGEU = op_31_26_d[6'b011011];

    wire t_branch = i_JIRL || i_JB || i_JBL || i_BEQZ || i_BEQ || i_BNEZ || i_BNE || i_BLT || i_BGE || i_BLTU || i_BGEU;
    // attention: auipc is assigned to branch unit
    wire [5:0] uop_branch=i_LUI12?4'b1011:i_AUIPC12?4'b1010:i_JIRL?4'b1001:(i_JB|i_JBL)?4'b1000:
        i_BEQZ?4'b0000:i_BNEZ?4'b0001:i_BEQ?4'b0010:i_BNE?4'b0011:i_BLT?4'b0100:i_BGE?4'b0101:i_BLTU?4'b0110:i_BGEU?4'b0111:4'b0000;




    wire i_CACOP = op_31_26_d[1] && op_25_22_d[8];



    wire t_RDCNT=op_31_26_d[0] && op_25_22_d[0] && op_21_20_d[0] && op_19_15_d[0] && (op_14_10_d['b11000]||op_14_10_d['b11001]);
    wire i_RDCNTID = t_RDCNT && op_14_10_d['b11000] && inst[9:5];
    wire i_RDCNTVL = t_RDCNT && op_14_10_d['b11000] && inst[4:0];
    wire i_RDCNTVH = t_RDCNT && op_14_10_d['b11001] && inst[4:0];

    wire t_csr_reg = op_31_26_d[1] && !inst[25:24];
    wire i_CSRRD = t_csr_reg && !inst[9:5];
    wire i_CSRWR = t_csr_reg && inst[9:5] == 'b1;
    wire i_CSRXCHG = t_csr_reg && inst[9:6];

    wire t_csr_TLB = op_31_26_d[1] && op_25_22_d[9] && op_21_20_d[0] && op_19_15_d[16];
    wire i_TLBSRCH = t_csr_TLB && op_14_10_d['b01010];
    wire i_TLBRD = t_csr_TLB && op_14_10_d['b01011];
    wire i_TLBWR = t_csr_TLB && op_14_10_d['b01100];
    wire i_TLBFILL = t_csr_TLB && op_14_10_d['b01101];
    wire i_INVTLB = op_31_26_d[1] && op_25_22_d[9] && op_21_20_d[0] && op_19_15_d['b10011] && inst[4:0] < 7;

    wire i_BREAK = op_31_26_d[0] && op_25_22_d[0] && op_21_20_d[2] && op_19_15_d['b10100];
    wire i_SYSCALL = op_31_26_d[0] && op_25_22_d[0] && op_21_20_d[2] && op_19_15_d['b10110];
    wire i_ERTN = t_csr_TLB && op_14_10_d['b01110];

    wire t_csr = t_RDCNT || t_csr_reg || t_csr_TLB || i_INVTLB || i_CACOP;

    wire inst_unsupported;
    wire t_exception = i_BREAK | i_SYSCALL | i_ERTN | fetch_exception != 0;
    assign exception = fetch_exception != 0 ? fetch_exception : i_BREAK ? 6 : i_SYSCALL ? 5 : i_ERTN ? 2 : inst_unsupported ? 4 : 0;
    wire [5:0] uop_CSR=t_exception?6'b0:i_RDCNTID?6'b100:i_RDCNTVH?6'b101:i_RDCNTVL?6'b110:i_CSRRD?6'b1000:i_CSRWR?6'b1001:i_CSRXCHG?6'b1010:
        i_TLBSRCH?6'b11010:i_TLBRD?6'b11011:i_TLBWR?6'b11100:i_TLBFILL?6'b11101:i_INVTLB?6'b11110:i_CACOP?{1'b1,inst[4:0]}:0;


    assign rd_addr = i_JBL ? 1 : i_RDCNTID ? inst[9:5] : inst[4:0];
    assign rs1_addr = inst[9:5];
    assign rs2_addr = (t_branch | t_store | t_csr_reg) ? inst[4:0] : inst[14:10];
    assign rs1_en = rs1_addr && (t_alu_i|t_alu_r|t_mdu_mul|t_mdu_div | t_load|t_store | t_branch&~i_JBL&~i_JB | i_CSRXCHG|i_CACOP|i_INVTLB);
    assign rs2_en = rs2_addr && (t_alu_r|t_mdu_mul|t_mdu_div | t_store | (i_BEQ|i_BNE|i_BLT|i_BGE|i_BLTU|i_BGEU) | i_CSRWR|i_CSRXCHG|i_INVTLB);
    assign rd_en = rd_addr && (t_alu_i|t_alu_r|t_mdu_mul|t_mdu_div | t_load | i_JIRL|i_JBL | i_LUI12|i_AUIPC12 | t_RDCNT|t_csr_reg);

    assign futype = {
        1'b0, 1'b0, t_csr, t_store | t_load, t_branch | i_AUIPC12, t_mdu_mul | t_mdu_div, t_alu_i | t_alu_r | i_LUI12
    };
    assign uop = futype[0] ? uop_alu : futype[1] ? uop_mdu : futype[2] ? uop_branch : futype[3] ? uop_load_store : futype[4] ? uop_CSR : 0;
    assign inst_unsupported = ~|futype;

    assign immediate = ((i_SLLI | i_SRLI | i_SRAI) ? {27'b0, inst[14:10]} :  //ui5
        (i_SLTI | i_SLTUI | i_ADDI) ? {{20{inst[21]}}, inst[21:10]} :  //si12
        (t_store | t_load | i_CACOP) ? {{20{inst[21]}}, inst[21:10]} :  //si12
        (i_ANDI | i_ORI | i_XORI) ? {20'b0, inst[21:10]} :  //ui12
        (i_LUI12 | i_AUIPC12) ? {inst[24:5], 12'b0} :  //si20
        (i_JB | i_JBL) ? {{4{inst[9]}}, inst[9:0], inst[25:10], 2'b00} :  //off26
        (i_BEQZ | i_BNEZ) ? {{9{inst[4]}}, inst[4:0], inst[25:10], 2'b00} :  //off21
        (i_JIRL | i_BEQ | i_BNE | i_BLT | i_BGE | i_BLTU | i_BGEU) ? {{14{inst[25]}}, inst[25:10], 2'b00} :  //off16
        t_csr_reg ? {18'b0, inst[23:10]} :  //csr14
        i_INVTLB ? {27'b0, inst[4:0]} :  // code5
        0);

endmodule

module decode_branch_loongarch (
    input wire [31:0] inst,
    output wire is_branch
);
    assign is_branch = inst[31:30] == 2'b01;

endmodule
