

`include "common.svh"

`default_nettype none

module memory_unit (
    input wire clk,
    input wire rst,

    request_interface.sender memory_read_req[2],
    data_transfer_interface.receiver memory_read_data[2],
    request_interface.sender memory_write_req[2],
    data_transfer_interface.sender memory_write_data[2],

    issue_execute_interface.execute   in,
    execute_commit_interface.execute  out,
    exception_throw_interface.execute throw,

    cache_TLB_interface.cache TLB,
    flush_pipeline_interface.pipeline flush_pipeline,
    input wire rob_id_t next_retire_inst_id,
    output data_t csr_badv_addr
);
    eu_inst_info inst_id;
    data_t rs1, rs2;
    immediate_t immediate;
    reg [2:0] funct;
    reg is_store;
    pipeline_stage_wire pipeline (
        .clk(clk),
        .rst(rst),
        .input_valid(in.valid),
        .this_allowin(in.allowin),
        .ready_go(1),
        .flush(flush_pipeline.flush || TLB.cacop_valid)
    );
    always @(posedge clk) begin
        if (pipeline.input_next) begin
            inst_id <= in.inst_id;
            rs1 <= in.rs1_data;
            rs2 <= in.rs2_data;
            immediate <= in.immediate;
            funct <= in.uop[2:0];
            is_store <= in.uop[5];
        end
    end
    wire data_t virt_address = rs1 + immediate;

    typedef struct packed {
        data_t virt_addr;
        logic [2:0] funct;
        eu_inst_info inst_id;
    } mem_req_info_t;
    memory_mask mask_in (
        .opcode (funct),
        .offset (virt_address[1:0]),
        .rs_data(rs2)
    );
    mem_req_info_t out_info;
    cache #($bits(
        mem_req_info_t
    )) dcache (
        .clk(clk),
        .rst(rst),
        .mem_cache_read_req(memory_read_req[0]),
        .mem_cache_read_data(memory_read_data[0]),
        .mem_cache_write_req(memory_write_req[0]),
        .mem_cache_write_data(memory_write_data[0]),
        .mem_mmio_read_req(memory_read_req[1]),
        .mem_mmio_read_data(memory_read_data[1]),
        .mem_mmio_write_req(memory_write_req[1]),
        .mem_mmio_write_data(memory_write_data[1]),

        .req_valid(pipeline.output_valid),
        .req_ready(pipeline.next_allowin),
        .req_virt_addr({virt_address[31:2], {2{mask_in.unaligned_access}}}),
        .req_info({virt_address, funct, inst_id}),
        .req_is_write(is_store),
        .req_write_data(mask_in.store_data),
        .req_write_strb(mask_in.store_strb),
        .resp_ready(1),
        .resp_info(out_info),

        .TLB(TLB),
        .flush(flush_pipeline.flush),
        .is_last_in_pipeline(out_info.inst_id.rob_id == next_retire_inst_id)
    );

    memory_mask mask_out (
        .opcode(out_info.funct),
        .offset(out_info.virt_addr[1:0]),
        .load_data(dcache.resp_data)
    );

    assign out.valid = dcache.resp_valid && ~dcache.resp_exception;
    assign out.inst_id = out_info.inst_id;
    assign out.rd_data = mask_out.rd_data;
    assign throw.valid = dcache.resp_valid && dcache.resp_exception;
    assign throw.rob_id = out_info.inst_id.rob_id;
    assign throw.exception = dcache.resp_exception;

    reg badv_valid;
    rob_id_t badv_rob_id;
    data_t badv_addr;
    always @(posedge clk) begin
        if (rst | flush_pipeline.flush) badv_valid <= 0;
        else if (throw.valid && (!badv_valid || compare_rob_age(out_info.inst_id.rob_id, badv_rob_id))) begin
            badv_valid  <= 1;
            badv_rob_id <= out_info.inst_id.rob_id;
            badv_addr   <= out_info.virt_addr;
        end
    end
    assign csr_badv_addr = badv_addr;
endmodule

module memory_mask (
    input wire [2:0] opcode,
    input wire [1:0] offset,
    input wire [31:0] load_data,
    output wire [31:0] rd_data,
    input wire [31:0] rs_data,
    output wire [31:0] store_data,
    output wire [3:0] store_strb,
    output wire unaligned_access
);
    wire memByte = opcode[1:0] == 2'b00, memHalf = opcode[1:0] == 2'b01, memWord = opcode[1:0] == 2'b10;
    wire off0 = offset == 2'b00, off1 = offset == 2'b01, off2 = offset == 2'b10, off3 = offset == 2'b11;
    wire unsigned_load = opcode[2];
    assign unaligned_access = memHalf & (off1 | off3) | memWord & ~off0;

    wire [7:0] readByte={8{off0}}&load_data[7:0]|
						{8{off1}}&load_data[15:8]|
						{8{off2}}&load_data[23:16]|
						{8{off3}}&load_data[31:24];
    wire [15:0] readHalf = off0 ? load_data[15:0] : load_data[31:16];

    assign rd_data={32{memByte}}&{{24{~unsigned_load&readByte[7]}},readByte}|
					{32{memHalf}}&{{16{~unsigned_load&readHalf[15]}},readHalf}|
					{32{memWord}}&load_data;

    assign store_strb={4{memByte}}&{4{off0}}&4'b0001|
					{4{memByte}}&{4{off1}}&4'b0010|
					{4{memByte}}&{4{off2}}&4'b0100|
					{4{memByte}}&{4{off3}}&4'b1000|
					{4{memHalf}}&{4{off0}}&4'b0011|
					{4{memHalf}}&{4{off2}}&4'b1100|
					{4{memWord}}&4'b1111;

    assign store_data={32{memByte&off0}}&rs_data|
					{32{memByte&off1}}&{rs_data[23:0],8'b0}|
					{32{memByte&off2}}&{rs_data[15:0],16'b0}|
					{32{memByte&off3}}&{rs_data[7:0],24'b0}|
					{32{memHalf&off0}}&rs_data|
					{32{memHalf&off2}}&{rs_data[15:0],16'b0}|
					{32{memWord}}&rs_data;
endmodule

/* module memory_order (
	input  wire   [2:0] funct,
	input  wire   [1:0] offset,
	input  data_t       Mem_rdata,
	output data_t       RF_wdata,
	input  data_t       RF_rdata,
	output data_t       Mem_wdata,
	output wire   [3:0] Mem_strb
);
	wire memByte = funct[1:0] == 2'b00, memHalf = funct[1:0] == 2'b01, memWord = funct[1:0] == 2'b10;

	wire [7:0] readByte = Mem_rdata >> offset * 8;
	wire [15:0] readHalf = Mem_rdata >> offset * 8;
	assign RF_wdata={32{memByte}}&{{24{~funct[2]&readByte[7]}},readByte}|
					{32{memHalf}}&{{16{~funct[2]&readHalf[15]}},readHalf}|
					{32{memWord}}&Mem_rdata;

	assign Mem_strb = {4{memByte}} & {1 << offset} | {4{memHalf}} & {2'b11 << offset} | {4{memWord}} & 4'b1111;

	assign Mem_wdata={32{memByte}}&{4{RF_rdata[7:0]}}|
					{32{memHalf}}&{2{RF_rdata[15:0]}}|
					{32{memWord}}&RF_rdata;
endmodule */
`default_nettype wire
