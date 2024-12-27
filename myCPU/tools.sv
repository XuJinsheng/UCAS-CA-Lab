`ifndef XJS_INCLUDE_TOOL
`define XJS_INCLUDE_TOOL



class tools #(
    P1 = 2,
    P2 = 2
);
    // P1: number, P2: width
    static function automatic [P2-1:0] select;
        input [P1-1:0] sel;
        input [P1-1:0][P2-1:0] in;
        integer i;
        select = 0;
        for (i = 0; i < P1; i = i + 1) begin
            if (sel[i]) begin
                select = in[i];
            end
        end
    endfunction

    // P1: number, P2: width
    /* static function [P1-1:0][P2-1:0] compress_valids;
		input [P1-1:0] valids;
		input [P1-1:0][P2-1:0] array;
		output [$clog2(P1+1)-1:0] cnt;
		integer i, j;
		for (i = 0; i < P1; i = i + 1) begin
			if (valids[i]) begin
				compress_valids[j] = array[i];
				j = j + 1;
			end
		end
		cnt = j;
	endfunction */

    // P1: addr_width
    static function [P1-1:0] encoder;
        input [(1<<P1)-1:0] in;
        integer i;
        encoder = 0;
        for (i = 0; i < (1 << P1); i = i + 1) begin
            if (in[i]) begin
                encoder = i;
            end
        end
    endfunction

    // P1: addr_width, P2: output number
    static function automatic [P2-1:0][P1-1:0] find_zeros;
        input [(1<<P1)-1:0] in;
        logic [P2-1:0][(1<<P1)-1:0] array;
        integer i;
        array[0] = in;
        for (i = 1; i < P2; i = i + 1) begin
            array[i] = array[i-1] | (array[i-1] + 1);
        end
        for (i = 0; i < P2; i = i + 1) begin
            find_zeros[i] = encoder(~array[i]);
        end
    endfunction

    // P1: addr_width
    static function [(1<<P1)-1:0] decoder;
        input [P1-1:0] in;
        decoder = 0;
        decoder[in] = 1;
    endfunction

    // P1: number, P2: width
    static function [P1-1:0] compare_valids;
        input [P1-1:0] valids;
        input [P1-1:0][P2-1:0] array;
        input [P2-1:0] value;
        integer i;
        for (i = 0; i < P1; i = i + 1) begin
            compare_valids[i] = valids[i] && (array[i] == value);
        end
    endfunction

endclass


interface pipeline_pass;
    logic valid, allowin;
    modport next(output valid, input allowin);
    modport prev(input valid, output allowin);
endinterface

module pipeline_stage_wire (
    input  wire clk,
    input  wire rst,
    input  wire input_valid,
    output wire this_allowin,
    output wire output_valid,
    input  wire next_allowin,
    input  wire ready_go,
    input  wire flush
);
    logic data_valid, working;
    assign this_allowin = !(data_valid || working) || ready_go && (next_allowin || flush);
    assign output_valid = data_valid && ready_go && ~flush;

    logic input_next, output_go;
    assign input_next = input_valid && this_allowin;
    assign output_go  = output_valid && next_allowin;
    always @(posedge clk) begin
        if (rst) data_valid <= 0;
        else if (this_allowin) data_valid <= input_next;
        else if (flush) data_valid <= 0;
    end
    always @(posedge clk) begin
        if (rst) working <= 0;
        else if (input_next) working <= 1;
        else if (ready_go) working <= 0;
    end
endmodule

module pipeline_stage (
    input wire clk,
    input wire rst,
    pipeline_pass.prev plprev,
    pipeline_pass.next plnext,
    input wire ready_go,
    input wire flush
);
    logic input_next, data_valid, working;

    pipeline_stage_wire stage (
        .clk(clk),
        .rst(rst),
        .input_valid(plprev.valid),
        .this_allowin(plprev.allowin),
        .next_allowin(plnext.allowin),
        .output_valid(plnext.valid),
        .ready_go(ready_go),
        .flush(flush)
    );
    assign input_next = stage.input_next;
    assign data_valid = stage.data_valid;
    assign working = stage.working;

endmodule


`endif
