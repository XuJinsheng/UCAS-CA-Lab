`include "common.svh"

`default_nettype none

typedef struct packed {
    logic G;
    logic [1:0] MAT;
    logic [1:0] PLV;
    logic D;
    logic V;
} tlb_entry_info_t;

interface CSR_ROB_interface;
    logic log_interrupt_in_rob;

    logic raise_exception;
    exception_t exception;
    logic exception_from_pc;
    data_t PC;
    logic flush_pipeline_tag_valid;
    modport ROB(
        input log_interrupt_in_rob, flush_pipeline_tag_valid,
        output raise_exception, exception, PC, exception_from_pc
    );
    modport CSR(
        output log_interrupt_in_rob, flush_pipeline_tag_valid,
        input raise_exception, exception, PC, exception_from_pc
    );
endinterface

`define CSR_CRMD 14'h00
`define CSR_PRMD 14'h01
`define CSR_EUEN 14'h02
`define CSR_ECFG 14'h04
`define CSR_ESTAT 14'h05
`define CSR_ERA 14'h06
`define CSR_BADV 14'h07
`define CSR_EENTRY 14'h0c
`define CSR_SAVE0 14'h30
`define CSR_SAVE1 14'h31
`define CSR_SAVE2 14'h32
`define CSR_SAVE3 14'h33
`define CSR_TID 14'h40
`define CSR_TCFG 14'h41
`define CSR_TVAL 14'h42
`define CSR_TICLR 14'h44
`define CSR_CRMD_PLV 1:0
`define CSR_CRMD_IE 2
`define CSR_CRMD_DA 3
`define CSR_CRMD_PG 4
`define CSR_CRMD_DATF 6:5
`define CSR_CRMD_DATM 8:7
`define CSR_PRMD_PPLV 1:0
`define CSR_PRMD_PIE 2
`define CSR_ECFG_LIE 12:0
`define CSR_ESTAT_IS10 1:0
`define CSR_ERA_PC 31:0
`define CSR_BADV_DATA 31:0
`define CSR_EENTRY_VA 31:6
`define CSR_SAVE_DATA 31:0
`define CSR_TID_TID 31:0
`define CSR_TCFG_EN 0
`define CSR_TCFG_PERIOD 1
`define CSR_TCFG_INITV 31:2
`define CSR_TICLR_CLR 0

`define CSR_TLBIDX 14'h10
`define CSR_TLBEHI 14'h11
`define CSR_TLBELO0 14'h12
`define CSR_TLBELO1 14'h13
`define CSR_ASID 14'h18
`define CSR_TLBRENTRY 14'h88
`define CSR_DMW0 14'h180  
`define CSR_DMW1 14'h181
`define CSR_TLBIDX_INDEX 3:0
`define CSR_TLBIDX_PS 29:24
`define CSR_TLBIDX_NE 31
`define CSR_TLBEHI_VPPN 31:13
`define CSR_TLBELO_V 0
`define CSR_TLBELO_D 1
`define CSR_TLBELO_PLV 3:2
`define CSR_TLBELO_MAT 5:4
`define CSR_TLBELO_G 6
`define CSR_TLBELO_INFO 6:0
`define CSR_TLBELO_PPN 32-5:8
`define CSR_ASID_ASID 9:0
`define CSR_ASID_ASIDBITS 23:16
`define CSR_TLBRENTRY_PA 31:6

module CSR_unit (
    input wire clk,
    input wire rst,

    issue_execute_interface.execute execute_in,
    execute_commit_interface.execute execute_out,
    exception_throw_interface.execute execute_throw,
    flush_pipeline_interface.pipeline execute_flush,
    CSR_ROB_fetch_interface.CSR ifetch,
    CSR_ROB_interface.CSR ROB,
    CSR_TLB_interface TLB,
    cache_TLB_interface.CSR cache[2],
    input wire data_t mem_unit_badv_addr
);
    parameter OP_RDCNTID=6'b100, OP_RDCNTVH=6'b101, OP_RDCNTVL=6'b110, OP_CSRRD=6'b1000, OP_CSRWR=6'b1001, OP_CSRXCHG=6'b1010;
    parameter OP_TLBSRCH=6'b11010, OP_TLBRD=6'b11011, OP_TLBWR=6'b11100, OP_TLBFILL=6'b11101, OP_INVTLB=6'b11110;

    typedef logic [13:0] csr_addr_t;
    typedef logic [31:0] csr_data_t;

    wire [1:0] current_plv;
    wire reg_write_en;
    csr_addr_t reg_op_addr;
    csr_data_t reg_read_data, reg_write_data, reg_write_mask;
    csr_data_t time_cnt_id;
    reg [63:0] time_cnt_val;


    eu_inst_info execute_inst_id;
    data_t execute_rs1, execute_rs2;
    data_t execute_PC;
    immediate_t execute_immediate;
    uop_t execute_uop;
    data_t execute_rd_data;
    wire uop_cacop = execute_uop[5];
    wire cacop_ready_go;
    pipeline_stage_wire pipeline_stage (
        .clk(clk),
        .rst(rst),
        .input_valid(execute_in.valid),
        .this_allowin(execute_in.allowin),
        .next_allowin(execute_out.allowin),
        .ready_go(~uop_cacop || cacop_ready_go),
        .flush(execute_flush.flush)
    );
    wire debug_csr_will_be_flushed = (pipeline_stage.working | pipeline_stage.data_valid) && pipeline_stage.flush;
    always @(posedge clk) begin
        if (pipeline_stage.input_next) begin
            execute_inst_id <= execute_in.inst_id;
            execute_rs1 <= execute_in.rs1_data;
            execute_rs2 <= execute_in.rs2_data;
            execute_immediate <= execute_in.immediate;
            execute_PC <= execute_in.pc;
            execute_uop <= execute_in.uop;
        end
    end
    wire uop_rdcntid=execute_uop==OP_RDCNTID, uop_rdcntvh=execute_uop==OP_RDCNTVH, uop_rdcntvl=execute_uop==OP_RDCNTVL, uop_csrrd=execute_uop==OP_CSRRD, uop_csrwr=execute_uop==OP_CSRWR, uop_csrxchg=execute_uop==OP_CSRXCHG;
    wire uop_tlbsrch=execute_uop==OP_TLBSRCH, uop_tlbrd=execute_uop==OP_TLBRD, uop_tlbwr=execute_uop==OP_TLBWR, uop_tlbfill=execute_uop==OP_TLBFILL, uop_invtlb=execute_uop==OP_INVTLB;
    wire uop_rdcnt = uop_rdcntid || uop_rdcntvh || uop_rdcntvl;

    wire need_flush_pipeline;
    exception_t execute_exception, cacop_exception;
    assign execute_exception = uop_cacop ? cacop_exception : (~uop_rdcnt && current_plv != 0) ? EXCEPTION_UNPRIVILEGE_INST : EXCEPTION_NONE;
    assign execute_out.valid = pipeline_stage.output_valid && (execute_exception == EXCEPTION_NONE);
    assign execute_out.inst_id = execute_inst_id;
    assign execute_out.rd_data = execute_rd_data;
    assign execute_throw.valid = pipeline_stage.output_valid && execute_exception != EXCEPTION_NONE;
    assign execute_throw.rob_id = execute_inst_id.rob_id;
    assign execute_throw.exception = execute_exception;
    assign ROB.flush_pipeline_tag_valid = pipeline_stage.output_valid && need_flush_pipeline;
    always_comb begin
        case (execute_uop)
            OP_RDCNTID: execute_rd_data = time_cnt_id;
            OP_RDCNTVH: execute_rd_data = time_cnt_val[63:32];
            OP_RDCNTVL: execute_rd_data = time_cnt_val[31:0];
            OP_CSRRD: execute_rd_data = reg_read_data;
            OP_CSRWR: execute_rd_data = reg_read_data;
            OP_CSRXCHG: execute_rd_data = reg_read_data;
            default: execute_rd_data = 0;
        endcase
    end

    assign reg_write_en = execute_out.valid && (uop_csrwr || uop_csrxchg);
    assign reg_op_addr = execute_immediate;
    assign reg_write_data = execute_rs2;
    assign reg_write_mask = uop_csrwr ? 32'hffffffff : execute_rs1;

    wire tlb_invtlb_valid = execute_out.valid && uop_invtlb;
    wire tlb_srch_valid = execute_out.valid && uop_tlbsrch;
    wire tlb_rd_valid = execute_out.valid && uop_tlbrd;
    wire tlb_wr_valid = execute_out.valid && uop_tlbwr;
    wire tlb_fill_valid = execute_out.valid && uop_tlbfill;
    assign need_flush_pipeline = tlb_rd_valid || tlb_wr_valid || tlb_fill_valid || tlb_invtlb_valid || uop_cacop
        || reg_write_en&&(reg_op_addr==`CSR_CRMD||reg_op_addr==`CSR_ASID||reg_op_addr==`CSR_DMW0||reg_op_addr==`CSR_DMW1);

    wire cacop_target = execute_uop[0];
    wire [31:0] cacop_va = execute_rs1 + execute_immediate;
    wire cacop_unprivilege = current_plv != 0 && execute_uop[4:3] == 3;
    wire cacop_unsupported = execute_uop[2:1] != 0;
    wire cacop_working = pipeline_stage.working && uop_cacop && ~cacop_unprivilege && ~cacop_unsupported;
    assign cache[0].cacop_valid = cacop_working && cacop_target == 0;
    assign cache[0].cacop_op = tools#(2)::decoder(execute_uop[4:3]);
    assign cache[0].cacop_va = cacop_va;
    assign cache[1].cacop_valid = cacop_working && cacop_target == 1;
    assign cache[1].cacop_op = tools#(2)::decoder(execute_uop[4:3]);
    assign cache[1].cacop_va = cacop_va;

    assign cacop_ready_go  = cacop_unprivilege || cacop_unsupported || cacop_target?cache[1].cacop_ready:cache[0].cacop_ready;
    assign cacop_exception = cacop_unprivilege ? EXCEPTION_UNPRIVILEGE_INST : cacop_unsupported ? EXCEPTION_UNSUPPORTED_INST : 
                            cacop_target ? cache[1].cacop_ex : cache[0].cacop_ex;

    reg badv_from_cacop;
    data_t badv_from_cacop_data;
    always @(posedge clk) begin
        if (rst || execute_flush.flush) badv_from_cacop <= 0;
        else if (cacop_working && cacop_exception != EXCEPTION_NONE) begin
            badv_from_cacop <= 1;
            badv_from_cacop_data <= cacop_va;
        end
    end











    wire raise_interrupt;
    wire catch_ex, catch_ertn;
    wire catch_tlb_refill, catch_from_pc;
    exception_t catch_etype;
    data_t catch_pc, catch_badv;
    assign ROB.log_interrupt_in_rob = raise_interrupt;
    assign catch_ex = ROB.raise_exception && catch_etype != EXCEPTION_ERTN && catch_etype != EXCEPTION_FLUSHPIPELINE;
    assign catch_ertn = ROB.raise_exception && catch_etype == EXCEPTION_ERTN;
    assign catch_tlb_refill = ROB.raise_exception && catch_etype == EXCEPTION_TLB_REFILL;
    assign catch_from_pc = ROB.exception_from_pc;
    assign catch_pc = ROB.PC;
    assign catch_badv = badv_from_cacop ? badv_from_cacop_data : catch_from_pc ? ROB.PC : mem_unit_badv_addr;
    always_comb begin
        catch_etype = ROB.exception;
        if (ROB.exception == EXCEPTION_ERTN && current_plv != 0) catch_etype = EXCEPTION_UNPRIVILEGE_INST;
    end



    // CRMD
    reg [1:0] csr_crmd_plv, csr_crmd_datf, csr_crmd_datm;
    reg csr_crmd_ie, csr_crmd_da, csr_crmd_pg;
    wire [31:0] csr_crmd = {23'b0, csr_crmd_datm, csr_crmd_datf, csr_crmd_pg, csr_crmd_da, csr_crmd_ie, csr_crmd_plv};
    assign current_plv = csr_crmd_plv;
    // PRMD
    reg [1:0] csr_prmd_pplv;
    reg csr_prmd_pie;
    wire [31:0] csr_prmd = {29'b0, csr_prmd_pie, csr_prmd_pplv};
    // ECFG
    reg [12:0] csr_ecfg_lie;
    wire [31:0] csr_ecfg = {19'b0, csr_ecfg_lie[12:11], 1'b0, csr_ecfg_lie[9:0]};
    // ESTAT
    reg [12:0] csr_estat_is;
    reg [5:0] csr_estat_ecode;
    reg [8:0] csr_estat_esubcode;
    wire [31:0] csr_estat = {
        1'b0, csr_estat_esubcode, csr_estat_ecode, 3'b0, csr_estat_is[12:11], 1'b0, csr_estat_is[9:0]
    };
    // ERA,BADV,EENTRY,SAVE-DATA
    data_t csr_era, csr_badv;
    reg [25:0] csr_eentry_va;
    wire data_t csr_eentry = {csr_eentry_va, 6'b0};
    data_t csr_save0_data, csr_save1_data, csr_save2_data, csr_save3_data;

    // TID&TCFG
    csr_data_t csr_tid;
    reg csr_tcfg_en;
    reg csr_tcfg_periodic;
    reg [29:0] csr_tcfg_initval;
    wire csr_data_t csr_tcfg = {csr_tcfg_initval, csr_tcfg_periodic, csr_tcfg_en};
    csr_data_t csr_tval;
    wire csr_data_t csr_ticlr = 0;

    // TLBIDX
    reg [3:0] csr_tlbidx_index;
    reg [5:0] csr_tlbidx_ps;
    reg csr_tlbidx_ne;
    wire [31:0] csr_tlbidx = {csr_tlbidx_ne, 1'b0, csr_tlbidx_ps, 8'b0, 12'b0, csr_tlbidx_index};
    // TLBEHI
    reg [18:0] csr_tlbehi_vppn;
    wire [31:0] csr_tlbehi = {csr_tlbehi_vppn, 13'b0};
    // TLBELO0,TLBELO1
    tlb_entry_info_t csr_tlblo0_info, csr_tlblo1_info;
    reg [19:0] csr_tlblo0_ppn, csr_tlblo1_ppn;
    wire [31:0] csr_tlblo0 = {4'b0, csr_tlblo0_ppn, 1'b0, csr_tlblo0_info};
    wire [31:0] csr_tlblo1 = {4'b0, csr_tlblo1_ppn, 1'b0, csr_tlblo1_info};
    // ASID
    reg  [ 9:0] csr_asid_asid;
    wire [31:0] csr_asid = {8'h0, 8'd10, 6'h0, csr_asid_asid};
    // TLBRENTRY
    reg  [25:0] csr_tlbrentry_pa;
    wire [31:0] csr_tlbrentry = {csr_tlbrentry_pa, 6'b0};
    // DMW0,DMW1
    reg [31:0] csr_dmw0, csr_dmw1;
    /* reg csr_dmw0_plv0, csr_dmw0_plv3, csr_dmw1_plv0, csr_dmw1_plv3;
    reg [1:0] csr_dmw0_mat, csr_dmw1_mat;
    reg [2:0] csr_dmw0_pseg, csr_dmw0_vseg, csr_dmw1_pseg, csr_dmw1_vseg;
    wire [31:0] csr_dmw0 = {
        csr_dmw0_vseg, 1'b0, csr_dmw0_pseg, 19'b0, csr_dmw0_mat, csr_dmw0_plv3, 2'b0, csr_dmw0_plv0
    };
    wire [31:0] csr_dmw1 = {
        csr_dmw1_vseg, 1'b0, csr_dmw1_pseg, 19'b0, csr_dmw1_mat, csr_dmw1_plv3, 2'b0, csr_dmw1_plv0
    }; */



    always_comb begin
        case (reg_op_addr)
            `CSR_CRMD: reg_read_data = csr_crmd;
            `CSR_PRMD: reg_read_data = csr_prmd;
            `CSR_ECFG: reg_read_data = csr_ecfg;
            `CSR_ESTAT: reg_read_data = csr_estat;
            `CSR_ERA: reg_read_data = csr_era;
            `CSR_BADV: reg_read_data = csr_badv;
            `CSR_EENTRY: reg_read_data = csr_eentry;
            `CSR_SAVE0: reg_read_data = csr_save0_data;
            `CSR_SAVE1: reg_read_data = csr_save1_data;
            `CSR_SAVE2: reg_read_data = csr_save2_data;
            `CSR_SAVE3: reg_read_data = csr_save3_data;
            `CSR_TID: reg_read_data = csr_tid;
            `CSR_TCFG: reg_read_data = csr_tcfg;
            `CSR_TVAL: reg_read_data = csr_tval;
            `CSR_TICLR: reg_read_data = csr_ticlr;
            `CSR_TLBIDX: reg_read_data = csr_tlbidx;
            `CSR_TLBEHI: reg_read_data = csr_tlbehi;
            `CSR_TLBELO0: reg_read_data = csr_tlblo0;
            `CSR_TLBELO1: reg_read_data = csr_tlblo1;
            `CSR_ASID: reg_read_data = csr_asid;
            `CSR_TLBRENTRY: reg_read_data = csr_tlbrentry;
            `CSR_DMW0: reg_read_data = csr_dmw0;
            `CSR_DMW1: reg_read_data = csr_dmw1;
            default: reg_read_data = 0;
        endcase
    end





    `define update_csr(csr_reg, csr_addr, csr_mask)\
	if (reg_write_en && reg_op_addr == csr_addr)\
            csr_reg <= reg_write_mask[csr_mask]&reg_write_data[csr_mask] | ~reg_write_mask[csr_mask] & csr_reg;
    //CRMD
    always @(posedge clk) begin
        if (rst) csr_crmd_plv <= 0;
        else if (catch_ex) csr_crmd_plv <= 0;
        else if (catch_ertn) csr_crmd_plv <= csr_prmd_pplv;
        else `update_csr(csr_crmd_plv, `CSR_CRMD, `CSR_CRMD_PLV);

        if (rst) csr_crmd_ie <= 1'b0;
        else if (catch_ex) csr_crmd_ie <= 1'b0;
        else if (catch_ertn) csr_crmd_ie <= csr_prmd_pie;
        else if (reg_write_en && reg_op_addr == `CSR_CRMD) `update_csr(csr_crmd_ie, `CSR_CRMD, `CSR_CRMD_IE);
    end
    always @(posedge clk) begin
        if (rst) csr_crmd_da <= 1;
        else if (catch_tlb_refill) csr_crmd_da <= 1;
        else if (catch_ertn && csr_estat_ecode == 'h3f) csr_crmd_da <= 0;
        else `update_csr(csr_crmd_da, `CSR_CRMD, `CSR_CRMD_DA);
        if (rst) csr_crmd_pg <= 0;
        else if (catch_tlb_refill) csr_crmd_pg <= 0;
        else if (catch_ertn && csr_estat_ecode == 'h3f) csr_crmd_pg <= 1;
        else `update_csr(csr_crmd_pg, `CSR_CRMD, `CSR_CRMD_PG);
        if (rst) csr_crmd_datf <= 0;
        else `update_csr(csr_crmd_datf, `CSR_CRMD, `CSR_CRMD_DATF);
        if (rst) csr_crmd_datm <= 0;
        else `update_csr(csr_crmd_datm, `CSR_CRMD, `CSR_CRMD_DATM);
    end

    //PRMD
    always @(posedge clk) begin
        if (catch_ex) csr_prmd_pplv <= csr_crmd_plv;
        else `update_csr(csr_prmd_pplv, `CSR_PRMD, `CSR_PRMD_PPLV)
        if (catch_ex) csr_prmd_pie <= csr_crmd_ie;
        else `update_csr(csr_prmd_pie, `CSR_PRMD, `CSR_PRMD_PIE)
    end

    // ECFG
    always @(posedge clk) begin
        if (rst) csr_ecfg_lie <= 13'b0;
        else `update_csr(csr_ecfg_lie, `CSR_ECFG, `CSR_ECFG_LIE)
    end

    // ESTAT
    always @(posedge clk) begin
        if (rst) csr_estat_is[1:0] <= 2'b0;
        else `update_csr(csr_estat_is[1:0], `CSR_ESTAT, `CSR_ESTAT_IS10)

        csr_estat_is[9:2] <= 0;  //hw_int_in[7:0];
        csr_estat_is[10]  <= 1'b0;
        if (csr_tval[31:0] == 32'b0) csr_estat_is[11] <= 1'b1;
        else if (reg_write_en && reg_op_addr == `CSR_TICLR && reg_write_mask[`CSR_TICLR_CLR] && reg_write_data[`CSR_TICLR_CLR])
            csr_estat_is[11] <= 1'b0;
        csr_estat_is[12] <= 0;  //ipi_int_in;
    end

    // ESTAT ECODE
    always @(posedge clk) begin
        if (catch_ex) begin
            case (catch_etype)
                EXCEPTION_INTERRUPT: csr_estat_ecode <= 'h0;
                EXCEPTION_UNPRIVILEGE_INST: csr_estat_ecode <= 'hE;
                EXCEPTION_UNSUPPORTED_INST: csr_estat_ecode <= 'hD;
                EXCEPTION_SYSCALL: csr_estat_ecode <= 'hB;
                EXCEPTION_BREAKPOINT: csr_estat_ecode <= 'hC;
                EXCEPTION_UNALIGNED: csr_estat_ecode <= catch_from_pc ? 'h8 : 'h9;
                EXCEPTION_TLB_REFILL: csr_estat_ecode <= 'h3F;
                EXCEPTION_LOAD_PAGE_FAULT: csr_estat_ecode <= catch_from_pc ? 'h3 : 'h1;
                EXCEPTION_STORE_PAGE_FAULT: csr_estat_ecode <= 'h2;
                EXCEPTION_MODIFY_PAGE_FAULT: csr_estat_ecode <= 'h4;
                EXCEPTION_PRIVILEGE_PAGE_FAULT: csr_estat_ecode <= 'h7;
                default: csr_estat_ecode <= 0;
            endcase
            csr_estat_esubcode <= 0;
        end
    end

    // ERA
    always @(posedge clk) begin
        if (catch_ex) csr_era <= catch_pc;
        else `update_csr(csr_era, `CSR_ERA, `CSR_ERA_PC)
    end
    //BADV
    always @(posedge clk) begin
        if (catch_ex) begin
            if (catch_etype >= EXCEPTION_UNALIGNED) csr_badv <= catch_badv;
        end else `update_csr(csr_badv, `CSR_BADV, `CSR_BADV_DATA)
    end

    // EENTRY
    always @(posedge clk) begin
        `update_csr(csr_eentry_va, `CSR_EENTRY, `CSR_EENTRY_VA);
    end

    // SAVE
    always @(posedge clk) begin
        `update_csr(csr_save0_data, `CSR_SAVE0, `CSR_SAVE_DATA);
        `update_csr(csr_save1_data, `CSR_SAVE1, `CSR_SAVE_DATA);
        `update_csr(csr_save2_data, `CSR_SAVE2, `CSR_SAVE_DATA);
        `update_csr(csr_save3_data, `CSR_SAVE3, `CSR_SAVE_DATA);
    end


    // TID
    always @(posedge clk) begin
        if (rst) csr_tid <= 0;  // coreid_in;
        else `update_csr(csr_tid, `CSR_TID, `CSR_TID_TID)
    end

    // TCFG
    always @(posedge clk) begin
        if (rst) csr_tcfg_en <= 1'b0;
        else `update_csr(csr_tcfg_en, `CSR_TCFG, `CSR_TCFG_EN)

        `update_csr(csr_tcfg_periodic, `CSR_TCFG, `CSR_TCFG_PERIOD)
        `update_csr(csr_tcfg_initval, `CSR_TCFG, `CSR_TCFG_INITV)
    end
    wire [31:0] tcfg_next_value = reg_write_mask & reg_write_data | ~reg_write_mask & csr_tcfg;
    always @(posedge clk) begin
        if (rst) csr_tval <= 32'hffffffff;
        else if (reg_write_en && reg_op_addr == `CSR_TCFG && tcfg_next_value[`CSR_TCFG_EN])
            csr_tval <= {tcfg_next_value[`CSR_TCFG_INITV], 2'b0};
        else if (csr_tcfg_en && csr_tval != 32'hffffffff) begin
            if (csr_tval[31:0] == 32'b0 && csr_tcfg_periodic) csr_tval <= {csr_tcfg_initval, 2'b0};
            else csr_tval <= csr_tval - 1'b1;
        end
    end



    //DMW
    always @(posedge clk) begin
        if (rst) csr_dmw0 <= 0;
        else `update_csr(csr_dmw0, `CSR_DMW0, 31:0);
        if (rst) csr_dmw1 <= 0;
        else `update_csr(csr_dmw1, `CSR_DMW1, 31:0);
    end
    // TLBRENTRY
    always @(posedge clk) begin
        `update_csr(csr_tlbrentry_pa, `CSR_TLBRENTRY, `CSR_TLBRENTRY_PA);
    end


    // TLBIDX
    always @(posedge clk) begin
        if (tlb_srch_valid && TLB.srch_e) csr_tlbidx_index <= TLB.srch_index;
        else `update_csr(csr_tlbidx_index, `CSR_TLBIDX, `CSR_TLBIDX_INDEX);
        if (tlb_rd_valid) csr_tlbidx_ps <= TLB.rd_e ? TLB.rd_ps : 0;
        else `update_csr(csr_tlbidx_ps, `CSR_TLBIDX, `CSR_TLBIDX_PS);
        if (tlb_srch_valid) csr_tlbidx_ne <= ~TLB.srch_e;
        else if (tlb_rd_valid) csr_tlbidx_ne <= ~TLB.rd_e;
        else `update_csr(csr_tlbidx_ne, `CSR_TLBIDX, `CSR_TLBIDX_NE);
    end
    // TLBEHI
    always @(posedge clk) begin
        if (tlb_rd_valid) csr_tlbehi_vppn <= TLB.rd_e ? TLB.rd_vppn : 0;
        else if (catch_ex && catch_etype >= EXCEPTION_TLB_REFILL) csr_tlbehi_vppn <= catch_badv[31:13];
        else `update_csr(csr_tlbehi_vppn, `CSR_TLBEHI, `CSR_TLBEHI_VPPN);
    end
    // TLBELO0,TLBELO1
    always @(posedge clk) begin
        if (tlb_rd_valid) begin
            csr_tlblo0_info = TLB.rd_e ? TLB.rd_info0 : 0;
            csr_tlblo0_ppn  = TLB.rd_e ? TLB.rd_ppn0 : 0;
            csr_tlblo1_info = TLB.rd_e ? TLB.rd_info1 : 0;
            csr_tlblo1_ppn  = TLB.rd_e ? TLB.rd_ppn1 : 0;
        end else begin
            `update_csr(csr_tlblo0_info, `CSR_TLBELO0, `CSR_TLBELO_INFO);
            `update_csr(csr_tlblo0_ppn, `CSR_TLBELO0, `CSR_TLBELO_PPN);
            `update_csr(csr_tlblo1_info, `CSR_TLBELO1, `CSR_TLBELO_INFO);
            `update_csr(csr_tlblo1_ppn, `CSR_TLBELO1, `CSR_TLBELO_PPN);
        end
    end
    // ASID
    always @(posedge clk) begin
        if (tlb_rd_valid) csr_asid_asid <= TLB.rd_e ? TLB.rd_asid : 0;
        else `update_csr(csr_asid_asid, `CSR_ASID, `CSR_ASID_ASID);
    end



    assign TLB.crmd_plv = csr_crmd_plv;
    assign TLB.crmd_da = csr_crmd_da;
    assign TLB.crmd_datf = csr_crmd_datf;
    assign TLB.crmd_datm = csr_crmd_datm;
    assign TLB.asid = csr_asid_asid;
    assign TLB.csr_dmw0 = csr_dmw0;
    assign TLB.csr_dmw1 = csr_dmw1;
    assign TLB.srch_va = {csr_tlbehi_vppn, 13'b0};
    assign TLB.rd_index = csr_tlbidx_index;
    assign TLB.wrenable = tlb_wr_valid | tlb_fill_valid;
    assign TLB.wr_index = tlb_fill_valid ? TLB.suggest_index : csr_tlbidx_index;
    assign TLB.wr_e = csr_estat_ecode == 'h3f ? 1 : ~csr_tlbidx_ne;
    assign TLB.wr_ps = csr_tlbidx_ps;
    assign TLB.wr_vppn = csr_tlbehi_vppn;
    assign TLB.wr_info0 = csr_tlblo0_info;
    assign TLB.wr_info1 = csr_tlblo1_info;
    assign TLB.wr_ppn0 = csr_tlblo0_ppn;
    assign TLB.wr_ppn1 = csr_tlblo1_ppn;
    assign TLB.wr_asid = csr_asid_asid;
    assign TLB.invtlb_valid = tlb_invtlb_valid;
    assign TLB.invtlb_op = execute_immediate;
    assign TLB.invtlb_asid = execute_rs1;
    assign TLB.invtlb_va = execute_rs2;




    assign time_cnt_id = csr_tid;
    always @(posedge clk) begin
        if (rst) time_cnt_val <= 0;
        else time_cnt_val <= time_cnt_val + 1;
    end



    assign ifetch.target_valid = catch_ex || catch_ertn;
    assign ifetch.target_pc = catch_ertn ? csr_era : catch_tlb_refill ? csr_tlbrentry : csr_eentry;

    assign raise_interrupt = (csr_estat_is & csr_ecfg_lie) != 0 && csr_crmd_ie;
endmodule
`default_nettype wire
