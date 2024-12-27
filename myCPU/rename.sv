

`include "common.svh"

interface rob_rename_interface ();

    logic free_valid;
    arch_addr_t rd_arch;
    phy_addr_t rd_phy, rd_origin;
    modport ROB(output free_valid, rd_phy, rd_origin, rd_arch);
    modport rename(input free_valid, rd_phy, rd_origin, rd_arch);
endinterface

module rename_unit (
    input wire clk,
    input wire rst,

    decode_rename_rob_dispatch_interface decoder,
    rob_rename_interface rob,
    data_write_interface.write readytable,
    flush_pipeline_interface.pipeline flush_pipeline
);
    // 注意：arch_en拉高，但如果addr是0的情况，这种情况应该在decode里解决
    wire rd_assign_valid = decoder.valid & decoder.rd_en & |decoder.rd_arch;
    wire flush = flush_pipeline.flush;  // rat,sprare_phy_addrs.rd_ptr,phy_addr_from_rst

    phy_addr_t [31:0] rat;  // register renameing table
    phy_addr_t phy_addr_from_rst;

    phy_addr_t [31:0] old_rat;
    phy_addr_t old_phy_addr_from_rst;
    reg [6:0] old_spare_phy_addrs_rd_ptr;

    fifo #(6, 6, 1, 0, 1) spare_phy_addrs (
        .clk(clk),
        .rst(rst),
        .push(rob.free_valid && rob.rd_origin),
        .push_data(rob.rd_origin),
        .pop(rd_assign_valid && ~|phy_addr_from_rst),
        .set_rd_ptr(flush),
        .set_rd_ptr_data(old_spare_phy_addrs_rd_ptr)
    );

    assign decoder.rename_ready = phy_addr_from_rst || ~spare_phy_addrs.empty;
    wire phy_addr_t rd_assign_addr = phy_addr_from_rst ? phy_addr_from_rst : spare_phy_addrs.pop_data;

    assign decoder.rd_phy = decoder.rd_en ? rd_assign_addr : 0;
    assign decoder.rs1_phy = decoder.rs1_en ? rat[decoder.rs1_arch] : 0;
    assign decoder.rs2_phy = decoder.rs2_en ? rat[decoder.rs2_arch] : 0;
    assign decoder.rd_origin = decoder.rd_en ? rat[decoder.rd_arch] : 0;
    assign readytable.wen = rd_assign_valid;
    assign readytable.addr = rd_assign_addr;
    assign readytable.data = 0;

    always @(posedge clk) begin
        if (rst) begin
            rat <= 0;
            phy_addr_from_rst <= 'hfff;
        end else if (flush) begin
            rat <= old_rat;
            phy_addr_from_rst <= old_phy_addr_from_rst;
        end else if (rd_assign_valid) begin
            rat[decoder.rd_arch] <= rd_assign_addr;
            if (phy_addr_from_rst) phy_addr_from_rst <= phy_addr_from_rst - 1;
        end
    end
    always @(posedge clk) begin
        if (rst) begin
            old_rat <= 0;
            old_phy_addr_from_rst <= 'hfff;
            old_spare_phy_addrs_rd_ptr <= 0;
        end else if (rob.free_valid && rob.rd_phy) begin
            old_rat[rob.rd_arch] <= rob.rd_phy;
            if (old_phy_addr_from_rst) old_phy_addr_from_rst <= old_phy_addr_from_rst - 1;
            else old_spare_phy_addrs_rd_ptr <= old_spare_phy_addrs_rd_ptr + 1;
        end
    end
endmodule
