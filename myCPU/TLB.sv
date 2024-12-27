`include "common.svh"

`default_nettype none
`define CSR_DMW_PLV0 0
`define CSR_DMW_PLV3 3
`define CSR_DMW_MAT 5:4
`define CSR_DMW_PSEG 27:25
`define CSR_DMW_VSEG 31:29
interface CSR_TLB_interface;
    logic [1:0] crmd_plv;
    logic [9:0] asid;
    logic crmd_da;  // 1:direct,0:translate
    logic crmd_datf;  // fetch: 1: cached, 0: mmio
    logic crmd_datm;  // memory: 1: cached, 0: mmio
    logic [31:0] csr_dmw0, csr_dmw1;

    logic invtlb_valid;
    logic [4:0] invtlb_op;
    logic [9:0] invtlb_asid;
    data_t invtlb_va;

    data_t srch_va;
    logic srch_e;
    logic [3:0] srch_index;

    logic [3:0] suggest_index;
    logic wrenable;
    logic wr_e;
    logic [3:0] wr_index;
    logic [9:0] wr_asid;
    logic [5:0] wr_ps;
    logic [18:0] wr_vppn;
    tlb_entry_info_t wr_info0;
    tlb_entry_info_t wr_info1;
    logic [19:0] wr_ppn0;
    logic [19:0] wr_ppn1;

    logic [3:0] rd_index;
    logic rd_e;
    logic [9:0] rd_asid;
    logic [18:0] rd_vppn;
    logic [5:0] rd_ps;
    tlb_entry_info_t rd_info0;
    tlb_entry_info_t rd_info1;
    logic [19:0] rd_ppn0;
    logic [19:0] rd_ppn1;

endinterface



module TLB_unit #(
    parameter TLBNUM = 16,
    parameter TLB_INDEX_WIDTH = 4
) (
    input wire clk,
    input wire rst,

    cache_TLB_interface.TLB cache[2],
    CSR_TLB_interface CSR
);
    reg [TLBNUM-1:0] tlb_E;
    reg [TLBNUM-1:0][9:0] tlb_ASID;
    reg [TLBNUM-1:0] tlb_G;
    reg [TLBNUM-1:0] tlb_PS4MB;  //reg [5:0] tlb_PS[TLBNUM];  // 12:4KB, 21: 2MB*2=4MB
    reg [TLBNUM-1:0][18:0] tlb_VPPN;
    reg [1:0] tlb_V[TLBNUM];
    reg [1:0] tlb_D[TLBNUM];
    reg [1:0][1:0] tlb_MAT[TLBNUM];  // 0: mmio, 1: cached
    reg [1:0][1:0] tlb_PLV[TLBNUM];  // 0: kernel, 3: user
    reg [1:0][19:0] tlb_PPN[TLBNUM];

    function automatic logic compare_vppn;
        input [TLB_INDEX_WIDTH-1:0] index;
        input [18:0] vppn;
        compare_vppn = tlb_VPPN[index][18:9] == vppn[18:9] && (tlb_PS4MB[index] || tlb_VPPN[index][8:0] == vppn[8:0]);
    endfunction
    function automatic [TLB_INDEX_WIDTH:0] search_tlb;
        input data_t va;
        search_tlb = 0;
        for (int i = 0; i < TLBNUM; i++) begin
            if (tlb_E[i] && (tlb_G[i] || tlb_ASID[i] == CSR.asid) && compare_vppn(i, va[31:13])) begin
                search_tlb = {i, 1'b1};
            end
        end
    endfunction

    function automatic [32+1+$bits(exception_t)-1:0] translate;  // is_mmio, exception, pa,
        input data_t va;
        input logic is_store;
        input logic is_fetch;
        if (va[1:0] != 0) translate = {1'b1, EXCEPTION_UNALIGNED, 32'b0};
        else if (CSR.crmd_da) translate = {is_fetch ? ~CSR.crmd_datf : ~CSR.crmd_datm, EXCEPTION_NONE, va};
        else if (CSR.csr_dmw0[CSR.crmd_plv] && CSR.csr_dmw0[`CSR_DMW_VSEG] == va[31:29])
            translate = {~CSR.csr_dmw0[`CSR_DMW_MAT], EXCEPTION_NONE, CSR.csr_dmw0[`CSR_DMW_PSEG], va[28:0]};
        else if (CSR.csr_dmw1[CSR.crmd_plv] && CSR.csr_dmw1[`CSR_DMW_VSEG] == va[31:29])
            translate = {~CSR.csr_dmw1[`CSR_DMW_MAT], EXCEPTION_NONE, CSR.csr_dmw1[`CSR_DMW_PSEG], va[28:0]};
        else begin
            logic [3:0] index;
            logic e, page;
            exception_t ex;
            {index, e} = search_tlb(va);
            page = tlb_PS4MB[index] ? va[21] : va[12];
            if (!e) ex = EXCEPTION_TLB_REFILL;
            else if (!tlb_V[index][page]) ex = is_store ? EXCEPTION_STORE_PAGE_FAULT : EXCEPTION_LOAD_PAGE_FAULT;
            else if (tlb_PLV[index][page] < CSR.crmd_plv) ex = EXCEPTION_PRIVILEGE_PAGE_FAULT;
            else if (~tlb_D[index][page] && is_store) ex = EXCEPTION_MODIFY_PAGE_FAULT;
            else ex = EXCEPTION_NONE;
            translate = {!tlb_MAT[index][page][0], ex, tlb_PPN[index][page], va[11:0]};
        end
    endfunction

    always_comb begin
        {cache[0].is_mmio, cache[0].exception, cache[0].phy_addr} =
            translate(cache[0].virt_addr, cache[0].is_store, 1);  //fetch
        {cache[1].is_mmio, cache[1].exception, cache[1].phy_addr} =
            translate(cache[1].virt_addr, cache[1].is_store, 0);  //load-store
        {CSR.srch_index, CSR.srch_e} = search_tlb(CSR.srch_va);  // TLB_SRCH
    end
    // read
    assign CSR.rd_e = tlb_E[CSR.rd_index];
    assign CSR.rd_vppn = tlb_VPPN[CSR.rd_index];
    assign CSR.rd_ps = tlb_PS4MB[CSR.rd_index] ? 21 : 12;
    assign CSR.rd_asid = tlb_ASID[CSR.rd_index];
    assign CSR.rd_info0 = {
        tlb_G[CSR.rd_index],
        tlb_MAT[CSR.rd_index][0],
        tlb_PLV[CSR.rd_index][0],
        tlb_D[CSR.rd_index][0],
        tlb_V[CSR.rd_index][0]
    };
    assign CSR.rd_info1 = {
        tlb_G[CSR.rd_index],
        tlb_MAT[CSR.rd_index][1],
        tlb_PLV[CSR.rd_index][1],
        tlb_D[CSR.rd_index][1],
        tlb_V[CSR.rd_index][1]
    };
    assign CSR.rd_ppn0 = tlb_PPN[CSR.rd_index][0];
    assign CSR.rd_ppn1 = tlb_PPN[CSR.rd_index][1];

    logic [TLBNUM-1:0] invtlb_mask;
    // write
    always_comb begin
        CSR.suggest_index = 0;
        for (int i = 0; i < TLBNUM; i++) begin
            if (!tlb_E[i]) CSR.suggest_index = i;
        end
    end
    always @(posedge clk) begin
        if (CSR.invtlb_valid) begin
            tlb_E = tlb_E & (~invtlb_mask);
        end else if (CSR.wrenable) begin
            tlb_E[CSR.wr_index] = CSR.wr_e;
            tlb_ASID[CSR.wr_index] = CSR.wr_asid;
            tlb_G[CSR.wr_index] = CSR.wr_info0.G && CSR.wr_info1.G;
            tlb_PS4MB[CSR.wr_index] = CSR.wr_ps == 21;
            tlb_VPPN[CSR.wr_index] = CSR.wr_vppn;
            tlb_V[CSR.wr_index] = {CSR.wr_info1.V, CSR.wr_info0.V};
            tlb_D[CSR.wr_index] = {CSR.wr_info1.D, CSR.wr_info0.D};
            tlb_MAT[CSR.wr_index] = {CSR.wr_info1.MAT, CSR.wr_info0.MAT};
            tlb_PLV[CSR.wr_index] = {CSR.wr_info1.PLV, CSR.wr_info0.PLV};
            tlb_PPN[CSR.wr_index] = {CSR.wr_ppn1, CSR.wr_ppn0};
        end
    end
    logic [TLBNUM-1:0] invtlb_cond1, invtlb_cond2, invtlb_cond3;
    always_comb begin
        for (int i = 0; i < TLBNUM; i++) begin
            invtlb_cond1[i] = tlb_G[i];
            invtlb_cond2[i] = tlb_ASID[i] == CSR.invtlb_asid;
            invtlb_cond3[i] = compare_vppn(i, CSR.invtlb_va[31:13]);
        end
        case (CSR.invtlb_op)
            0: invtlb_mask = {TLBNUM{1'b1}};
            1: invtlb_mask = {TLBNUM{1'b1}};
            2: invtlb_mask = invtlb_cond1;
            3: invtlb_mask = ~invtlb_cond1;
            4: invtlb_mask = ~invtlb_cond1 & invtlb_cond2;
            5: invtlb_mask = ~invtlb_cond1 & invtlb_cond2 & invtlb_cond3;
            6: invtlb_mask = (invtlb_cond1 | invtlb_cond2) & invtlb_cond3;
            default: invtlb_mask = 0;
        endcase
    end

endmodule
`default_nettype wire
