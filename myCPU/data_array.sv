`timescale 10 ns / 1 ns
`include "common.svh"

interface data_read_interface #(
    parameter ADDR_WIDTH = 6,
    parameter DATA_WIDTH = 32
);
    logic [ADDR_WIDTH-1:0] addr;
    logic [DATA_WIDTH-1:0] data;
    modport read(output addr, input data);
    modport data_array(input addr, output data);
endinterface

interface data_write_interface #(
    parameter ADDR_WIDTH = 6,
    parameter DATA_WIDTH = 32
);
    logic wen;
    logic [ADDR_WIDTH-1:0] addr;
    logic [DATA_WIDTH-1:0] data;
    modport write(output wen, addr, data);
    modport data_array(input wen, addr, data);
endinterface

module reg_file #(
    parameter ADDR_WIDTH   = 6,
    parameter DATA_WIDTH   = 32,
    parameter READ_PORTS   = 2,
    parameter WRITE_PORTS  = 1,
    parameter ZERO_DEFUALT = 0
) (
    input wire clk,
    input wire rst,
    data_read_interface.data_array read[READ_PORTS],
    data_write_interface.data_array write[WRITE_PORTS]
);
    reg [(1<<ADDR_WIDTH)-1:0][DATA_WIDTH-1:0] array;
    generate
        if (READ_PORTS > 0) begin
            for (genvar i = 0; i < READ_PORTS; i++) begin
                assign read[i].data = read[i].addr == 0 ? ZERO_DEFUALT : array[read[i].addr];
            end
        end
        if (WRITE_PORTS > 0) begin
            wire [WRITE_PORTS-1:0] wen;
            wire [WRITE_PORTS-1:0][ADDR_WIDTH-1:0] waddr;
            wire [WRITE_PORTS-1:0][DATA_WIDTH-1:0] wdata;
            for (genvar i = 0; i < WRITE_PORTS; i++) begin
                assign wen[i]   = write[i].wen;
                assign waddr[i] = write[i].addr;
                assign wdata[i] = write[i].data;
            end
            always @(posedge clk) begin
                for (integer i = 0; i < WRITE_PORTS; i++) begin
                    if (wen[i]) array[waddr[i]] <= wdata[i];
                end
            end
        end
    endgenerate
endmodule



module fifo #(
    ADDR_WIDTH = 4,
    DATA_WIDTH = 32,
    USE_RAM = 1,
    RANDOM_SET_WR_PTR = 0,
    RANDOM_SET_RD_PTR = 0
) (
    input wire clk,
    input wire rst,

    input wire push,
    input wire [DATA_WIDTH-1:0] push_data,
    input wire pop,
    output wire [DATA_WIDTH-1:0] pop_data,

    input wire set_wr_ptr,
    input wire [ADDR_WIDTH:0] set_wr_ptr_data,
    input wire set_rd_ptr,
    input wire [ADDR_WIDTH:0] set_rd_ptr_data
);
    reg [DATA_WIDTH-1:0] data[1<<ADDR_WIDTH];
    typedef logic [ADDR_WIDTH:0] ptr_t;

    wire full, empty;
    ptr_t wr_ptr, rd_ptr;

    assign full = (wr_ptr[ADDR_WIDTH] ^ rd_ptr[ADDR_WIDTH]) && wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0];
    assign empty = (wr_ptr[ADDR_WIDTH] == rd_ptr[ADDR_WIDTH]) && wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0];
    assign pop_data = data[rd_ptr[ADDR_WIDTH-1:0]];

    wire invalid_pop = empty && pop, invalid_push = full && push;
    always @(posedge clk) begin
        if (rst) rd_ptr <= 0;
        else if (set_rd_ptr && RANDOM_SET_RD_PTR) rd_ptr <= set_rd_ptr_data;
        else if (~empty & pop) rd_ptr <= rd_ptr + 1;
    end
    always @(posedge clk) begin
        if (rst) wr_ptr <= 0;
        else if (set_wr_ptr && RANDOM_SET_WR_PTR) wr_ptr <= set_wr_ptr_data;
        else if (~full & push) wr_ptr <= wr_ptr + 1;
    end
    always @(posedge clk) begin
        if (~full & push) data[wr_ptr[ADDR_WIDTH-1:0]] <= push_data;
    end

endmodule

/*
module fifo4 #(
	ADDR_WIDTH = 4,
	DATA_WIDTH = 32,
	USE_RAM = 1,
	RANDOM_READS = 1,
	RANDOM_WRITES = 1
) (
	input wire clk,
	input wire rst,

	input wire [1:0] push_cnt,
	input wire [3:0][DATA_WIDTH-1:0] push_data,

	input wire [1:0] pop_cnt,

	input wire set_wr_ptr,
	input wire [ADDR_WIDTH:0] set_wr_ptr_data,

	input wire [RANDOM_READS-1:0][ADDR_WIDTH-1:0] random_rptr,

	input wire [RANDOM_WRITES-1:0] random_wen,
	input wire [RANDOM_WRITES-1:0][ADDR_WIDTH-1:0] random_wptr,
	input wire [RANDOM_WRITES-1:0][DATA_WIDTH-1:0] random_wdata
);
	generate
		if (USE_RAM) begin
			reg [DATA_WIDTH-1:0] data[3:0][(1<<(ADDR_WIDTH-2))-1:0];
		end else begin
			reg [3:0][(1<<(ADDR_WIDTH-2))-1:0][DATA_WIDTH-1:0] data;
		end
	endgenerate
	typedef logic [ADDR_WIDTH:0] ptr_t;

	wire full, empty;
	ptr_t wr_ptr, rd_ptr;
	wire [3:0][DATA_WIDTH-1:0] pop_data;


endmodule
*/
