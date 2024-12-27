`include "common.svh"

`define CACHE_WAY 4
`define CACHE_SET 256
`define LINE_LEN 128
`define TAG_LEN 20
`define INDEX_LEN 8
`define DATA_LEN 4
`default_nettype none

interface request_interface;
    logic valid, ready;
    logic [7:0] len;
    data_t addr;
    modport sender(output valid, addr, len, input ready);
    modport receiver(input valid, addr, len, output ready);
endinterface

interface data_transfer_interface;
    logic valid, ready, last;
    data_t data;
    logic [3:0] wstrb;
    modport sender(output valid, data, last, wstrb, input ready);
    modport receiver(input valid, data, last, wstrb, output ready);
endinterface

typedef struct packed {
    logic [`TAG_LEN-1:0] tag;
    logic [`INDEX_LEN-1:0] index;
    logic [`DATA_LEN-1-2:0] word;
    logic [1:0] offset_bytes;
} address_t;

typedef logic [`LINE_LEN-1:0] line_data_t;



module tree_lru (
    input  wire                  clk,
    input  wire                  rst,
    input  wire [`INDEX_LEN-1:0] index,
    input  wire [`CACHE_WAY-1:0] valids,
    output wire [           1:0] evict_way,
    input  wire [           1:0] hit_way,
    input  wire                  hit_en
);
    reg [`CACHE_SET-1:0][`CACHE_WAY-2:0] lru_cnt;
    wire [`CACHE_WAY-2:0] select_lru = lru_cnt[index];

    wire [`CACHE_WAY-1:0] select_valid = valids;
    /* assign evict_way = (~select_valid[0]) ? 0 : (~select_valid[1]) ? 1 : (~select_valid[2]) ? 2 : (~select_valid[3]) ? 3
			: (select_lru[0] ? (select_lru[1] ? 0 : 1) : (select_lru[2] ? 2 : 3)); */
    assign evict_way = (~select_valid[0]) ? 0 : (~select_valid[1]) ? 1 : (select_lru[1] ? 0 : 1);

    wire [`CACHE_WAY-2:0] lru_next = hit_way[1] ? {hit_way[0], select_lru[1], 1'b1} : {select_lru[2], hit_way[0], 1'b0};
    always @(posedge clk) begin
        if (rst) lru_cnt <= 0;
        else if (hit_en) lru_cnt[index] <= lru_next;
    end
endmodule


module refill_unit (
    input wire clk,
    input wire rst,

    request_interface.sender mem_cache_read_req,
    data_transfer_interface.receiver mem_cache_read_data,
    request_interface.sender mem_cache_write_req,
    data_transfer_interface.sender mem_cache_write_data,

    output wire             working,
    input  wire             no_read_input_valid,  // 和input_valid是两种请求
    input  wire             input_valid,
    input  address_t        read_addr,
    input  wire             write_valid,
    input  address_t        write_addr,
    input  wire line_data_t write_data,

    output address_t   refill_addr,
    output wire        refill_valid,
    output line_data_t refill_data,
    output wire        refill_wr_finish,

    input  wire [1:0] read_evict_way,
    output reg  [1:0] refill_way
);
    localparam S_WAIT = 0, S_REQ = 1, S_RD = 2, S_REFILL = 3, S_WEQ = 4, S_WB = 5;
    reg [5:0] state, next_state;
    always @(posedge clk) begin
        if (rst) state <= 1 << S_WAIT;
        else state <= next_state;
    end
    assign working = ~state[S_WAIT];

    reg has_write, input_delay_countdown;
    address_t raddr, waddr;
    reg [1:0] mem_recv_cnt, mem_write_cnt;
    line_data_t mem_recv_data, mem_write_data;
    always @(posedge clk) begin
        if (state[S_WAIT] && (input_valid || no_read_input_valid)) begin
            input_delay_countdown <= 1;
            raddr <= read_addr;
        end else input_delay_countdown <= 0;
    end
    always @(posedge clk) begin
        if (input_delay_countdown || no_read_input_valid) begin
            has_write <= write_valid;
            waddr <= write_addr;
            refill_way <= read_evict_way;
            mem_write_data <= write_data;
        end
    end

    always @(posedge clk) begin
        if (state[S_WAIT] || state[S_REQ]) mem_recv_cnt <= 0;
        else if (mem_cache_read_data.valid && mem_cache_read_data.ready) mem_recv_cnt <= mem_recv_cnt + 1;
        if (state[S_WAIT] || state[S_WEQ]) mem_write_cnt <= 0;
        else if (mem_cache_write_data.valid && mem_cache_write_data.ready) mem_write_cnt <= mem_write_cnt + 1;
        if (mem_cache_read_data.valid) mem_recv_data[mem_recv_cnt*32+:32] <= mem_cache_read_data.data;
    end


    assign refill_addr = raddr;
    assign refill_valid = state[S_REFILL];
    assign refill_data = mem_recv_data;
    assign refill_wr_finish = state[S_WB] && mem_cache_write_data.ready && mem_cache_write_data.last;// used for cacop finish

    always @(*) begin
        case (state)
            1 << S_WAIT: next_state = input_valid ? 1 << S_REQ : no_read_input_valid ? 1 << S_WEQ : 1 << S_WAIT;
            1 << S_REQ: next_state = mem_cache_read_req.ready ? 1 << S_RD : 1 << S_REQ;
            1 << S_RD: next_state = mem_cache_read_data.valid && mem_cache_read_data.last ? 1 << S_REFILL : 1 << S_RD;
            1 << S_REFILL: next_state = has_write ? 1 << S_WEQ : 1 << S_WAIT;
            1 << S_WEQ: next_state = mem_cache_write_req.ready ? 1 << S_WB : 1 << S_WEQ;
            1 << S_WB: next_state = mem_cache_write_data.ready && mem_cache_write_data.last ? 1 << S_WAIT : 1 << S_WB;
            default: next_state = 1 << S_WAIT;
        endcase
    end
    assign mem_cache_read_req.valid = state[S_REQ];
    assign mem_cache_read_req.len = 3;
    assign mem_cache_read_req.addr = {raddr.tag, raddr.index, `DATA_LEN'b0};
    assign mem_cache_read_data.ready = state[S_RD];
    assign mem_cache_write_req.valid = state[S_WEQ];
    assign mem_cache_write_req.len = 3;
    assign mem_cache_write_req.addr = {waddr.tag, waddr.index, `DATA_LEN'b0};
    assign mem_cache_write_data.valid = state[S_WB];
    assign mem_cache_write_data.data = mem_write_data[mem_write_cnt*32+:32];
    assign mem_cache_write_data.wstrb = 4'b1111;
    assign mem_cache_write_data.last = state[S_WB] && mem_write_cnt == 3;
endmodule

interface cache_TLB_interface #(
    parameter IS_FETCH = 1
);
    logic is_store;
    data_t virt_addr;
    logic is_mmio;
    data_t phy_addr;
    exception_t exception;

    logic cacop_valid, cacop_ready;
    logic [2:0] cacop_op;
    data_t cacop_va;
    exception_t cacop_ex;
    modport cache(
        output virt_addr, is_store,
        input phy_addr, exception, is_mmio,
        output cacop_ready, cacop_ex,
        input cacop_valid, cacop_op, cacop_va
    );
    modport TLB(input virt_addr, is_store, output phy_addr, exception, is_mmio);
    modport CSR(input cacop_ready, cacop_ex, output cacop_valid, cacop_op, cacop_va);
endinterface


module cache #(
    parameter REQ_INFO_WIDTH = 1
) (
    input wire clk,
    input wire rst,

    request_interface.sender mem_cache_read_req,
    request_interface.sender mem_mmio_read_req,
    data_transfer_interface.receiver mem_cache_read_data,
    data_transfer_interface.receiver mem_mmio_read_data,
    request_interface.sender mem_cache_write_req,
    request_interface.sender mem_mmio_write_req,
    data_transfer_interface.sender mem_cache_write_data,
    data_transfer_interface.sender mem_mmio_write_data,

    input wire req_valid,
    output wire req_ready,
    input wire data_t req_virt_addr,
    input wire [REQ_INFO_WIDTH-1:0] req_info,
    input wire req_is_write,
    input wire data_t req_write_data,
    input wire [3:0] req_write_strb,

    output wire resp_valid,
    input wire resp_ready,
    output data_t resp_data,
    output exception_t resp_exception,
    output wire [REQ_INFO_WIDTH-1:0] resp_info,
    output wire resp_mmio,

    cache_TLB_interface.cache TLB,

    input wire flush,
    input wire is_last_in_pipeline
);
    typedef logic [REQ_INFO_WIDTH-1:0] req_info_t;
    parameter C_WAIT = 0, C_START = 1, C_READ_TAG = 2, C_TAG = 3, C_WB = 4, C_END = 5;
    reg [5:0] c_state, c_state_next;
    always @(posedge clk) begin
        if (rst) c_state <= 1 << C_WAIT;
        else c_state = c_state_next;
    end

    wire s1_ready_go;
    address_t s1_virt_addr;
    data_t s1_write_data;
    reg s1_is_write;
    reg [3:0] s1_write_strb;
    req_info_t s1_info;
    pipeline_stage_wire pl1 (
        .clk(clk),
        .rst(rst),
        .input_valid(req_valid && c_state[C_WAIT]),
        .ready_go(s1_ready_go | flush),
        .flush(flush)
    );
    assign req_ready = pl1.this_allowin && c_state[C_WAIT];
    always @(posedge clk) begin
        if (pl1.input_next || c_state[C_START]) begin
            s1_virt_addr  <= c_state[C_START] ? TLB.cacop_va : req_virt_addr;
            s1_write_data <= req_write_data;
            s1_is_write   <= c_state[C_START] ? 0 : req_is_write;
            s1_write_strb <= req_write_strb;
            s1_info       <= req_info;
        end
    end
    assign TLB.is_store  = s1_is_write;
    assign TLB.virt_addr = c_state[C_READ_TAG] ? {s1_virt_addr.tag, s1_virt_addr.index, `DATA_LEN'b0} : s1_virt_addr;




    wire s2_ready_go;

    wire [`CACHE_WAY-1:0][`TAG_LEN:0] s2_read_tag;
    wire [`CACHE_WAY-1:0][3:0][`LINE_LEN/4-1:0] s2_read_data;
    wire [`CACHE_WAY-1:0] s2_read_dirty;
    logic [`CACHE_WAY-1:0] s2_read_valid;
    logic [`CACHE_WAY-1:0] s2_hit_array;
    logic [1:0] s2_hit_way;


    // operation argument
    address_t s2_phy_addr;
    reg s2_is_write;
    reg s2_is_mmio;
    req_info_t s2_info;
    data_t s2_write_data;
    reg [3:0] s2_write_strb;

    exception_t s2_exception;


    // s2 operation, s2_*不是互斥的，*working是互斥的
    wire s2_ex = s2_exception != EXCEPTION_NONE;
    wire s2_mmio = s2_is_mmio;
    wire s2_hit = |s2_hit_array;
    wire s2_refill = ~s2_ex && ~s2_mmio && ~s2_hit;
    wire s2_cache_working = pl2.working && ~flush && (c_state[C_WAIT] || c_state[C_START]);
    wire ex_working = s2_cache_working && s2_ex;
    wire mmio_working = s2_cache_working && ~s2_ex && s2_mmio && is_last_in_pipeline;
    wire hit_working = s2_cache_working && ~s2_ex && ~s2_mmio && s2_hit && (~s2_is_write || is_last_in_pipeline);
    wire refill_working = s2_cache_working && s2_refill && (~s2_is_write || is_last_in_pipeline);



    pipeline_stage_wire pl2 (
        .clk(clk),
        .rst(rst),
        .input_valid(pl1.output_valid),
        .this_allowin(pl1.next_allowin),
        .output_valid(resp_valid),
        .next_allowin(resp_ready),
        .ready_go(s2_ready_go | flush),
        .flush(flush)
    );
    always @(posedge clk) begin
        if (pl2.input_next || c_state[C_READ_TAG]) begin
            s2_phy_addr <= TLB.phy_addr;
            s2_info <= s1_info;
            s2_exception <= TLB.exception;
            s2_is_mmio <= TLB.is_mmio;
            s2_write_data <= s1_write_data;
            s2_is_write <= s1_is_write;
            s2_write_strb <= s1_write_strb;
        end
    end

    always_comb begin
        s2_hit_way = 0;
        for (int i = 0; i < `CACHE_WAY; i++) begin
            s2_read_valid[i] = s2_read_tag[i][`TAG_LEN];
            s2_hit_array[i]  = s2_read_valid[i] && s2_read_tag[i][`TAG_LEN-1:0] == s2_phy_addr.tag;
            if (s2_hit_array[i]) s2_hit_way = i;
        end
    end
    wire data_t hit_data = s2_read_data[s2_hit_way][s2_phy_addr.word];


    data_t mmio_rdata;
    wire mmio_finish = s2_is_write ? mem_mmio_write_data.ready : mem_mmio_read_data.valid;
    assign mem_mmio_read_req.valid = mmio_working && ~s2_is_write;
    assign mem_mmio_read_req.addr = s2_phy_addr;
    assign mem_mmio_read_req.len = 0;
    assign mem_mmio_read_data.ready = resp_ready;
    assign mmio_rdata = mem_mmio_read_data.data;
    assign mem_mmio_write_req.valid = mmio_working && s2_is_write;
    assign mem_mmio_write_req.addr = s2_phy_addr;
    assign mem_mmio_write_req.len = 0;
    assign mem_mmio_write_data.valid = mmio_working && s2_is_write;
    assign mem_mmio_write_data.last = mmio_working && s2_is_write;
    assign mem_mmio_write_data.data = s2_write_data;
    assign mem_mmio_write_data.wstrb = s2_write_strb;


    // refill state 
    wire [1:0] evict_way;
    wire [1:0] refill_way;
    wire refill_unit_working;
    wire refill_valid;
    wire refill_wr_finish;
    address_t refill_addr;
    line_data_t refill_data;

    reg refill_finish;
    always @(posedge clk) begin
        refill_finish = refill_valid && {refill_addr.tag, refill_addr.index} == {s2_phy_addr.tag, s2_phy_addr.index};
    end

    wire s1_s2_conflict = s2_is_write && ~s1_is_write && (hit_working||refill_finish) && s1_virt_addr.word == s2_phy_addr.word;
    assign s1_ready_go = ~refill_unit_working && ~refill_finish && ~s1_s2_conflict;
    assign s2_ready_go = s2_ex ? 1 : s2_mmio ? mmio_finish : s2_hit? (~s2_is_write || is_last_in_pipeline) : refill_finish;
    assign resp_data = s2_mmio ? mmio_rdata : refill_finish ? refill_data[s2_phy_addr.word*32+:32] : hit_data;
    assign resp_exception = s2_exception;
    assign resp_info = s2_info;
    assign resp_mmio = s2_mmio;

    reg [2:0] cacop_op;
    always @(posedge clk) begin
        if (TLB.cacop_valid) cacop_op <= TLB.cacop_op;
    end
    wire [1:0] cacop_wr_way = cacop_op[2] ? s2_hit_way : s1_virt_addr;
    wire cacop_need_clear = cacop_op[0] || cacop_op[1] || cacop_op[2] && !s2_ex && s2_hit;
    wire cacop_need_write = (cacop_op[1] || cacop_op[2] && !s2_ex && s2_hit)
                            && s2_read_dirty[cacop_wr_way] && s2_read_tag[cacop_wr_way][`TAG_LEN];

    assign TLB.cacop_ready = c_state[C_END];
    assign TLB.cacop_ex = cacop_op[2] ? s2_exception : EXCEPTION_NONE;
    always_comb begin
        case (c_state)
            1 << C_WAIT: c_state_next = TLB.cacop_valid ? 1 << C_START : 1 << C_WAIT;
            1 << C_START: c_state_next = (refill_unit_working || pl2.working) ? 1 << C_START : 1 << C_READ_TAG;
            1 << C_READ_TAG: c_state_next = 1 << C_TAG;
            1 << C_TAG: c_state_next = cacop_need_write ? 1 << C_WB : 1 << C_END;
            1 << C_WB: c_state_next = refill_wr_finish ? 1 << C_END : 1 << C_WB;
            1 << C_END: c_state_next = 1 << C_WAIT;
            default: c_state_next = 1 << C_WAIT;
        endcase
    end




    tree_lru treelru (
        .clk(clk),
        .rst(rst),
        .index(s2_phy_addr.index),
        .valids(s2_read_valid),
        .evict_way(evict_way),
        .hit_way(s2_hit_way),
        .hit_en(hit_working)
    );
    refill_unit refill (
        .*,  // clk/rst, mem_channel, refill_*
        .working(refill_unit_working),
        .no_read_input_valid(c_state[C_WB]),
        .input_valid(refill_working),
        .read_addr(s2_phy_addr),
        .read_evict_way(evict_way),
        .write_valid(s2_read_dirty[evict_way] && s2_read_valid[evict_way]),
        .write_addr({
            s2_read_tag[c_state[C_WB]?cacop_wr_way : evict_way][`TAG_LEN-1:0], s2_phy_addr.index, `DATA_LEN'b0
        }),
        .write_data(s2_read_data[c_state[C_WB]?cacop_wr_way : evict_way])
    );


    /*
        refill 工作时阻塞s1（即使指令不相关）
        读写data端口
        refill：启动时，evict行dirty,tag,bank
            回填：evict行dirty,tag,bank
        stage2：读：不需要，写：addr对应的bank和dirty
        stage1：写：WAY个tag，读+WAY个bank
    */
    typedef logic [`INDEX_LEN-1:0] index_t;
    typedef logic [`CACHE_WAY-1:0] cache_way_t;
    logic adirty_ren, adirty_wen;
    logic [1:0] adirty_wen_way;
    index_t adirty_index;
    logic adirty_wdata;
    index_t atag_index;
    cache_way_t atag_ren;
    cache_way_t atag_wen;
    logic [`TAG_LEN:0] atag_wdata;
    index_t [3:0] adata_index;
    logic [`CACHE_WAY-1:0][3:0] adata_ren;
    logic [`CACHE_WAY-1:0][3:0][3:0] adata_wen;
    data_t [3:0] adata_wdata;
    always_comb begin
        adirty_ren = 0;
        adirty_wen = 0;
        adirty_wen_way = 0;
        adirty_index = 0;
        adirty_wdata = 0;
        atag_index = 0;
        atag_ren = 0;
        atag_wen = 0;
        atag_wdata = 0;
        adata_index = 0;
        adata_ren = 0;
        adata_wen = 0;
        adata_wdata = 0;
        if (c_state[C_READ_TAG] || c_state[C_TAG] || c_state[C_WB] || c_state[C_END]) begin
            adirty_index = s1_virt_addr.index;
            atag_index = s1_virt_addr.index;
            adata_index = {4{s1_virt_addr.index}};
            adirty_ren = 1;
            atag_ren = `CACHE_WAY'b1;
            atag_ren = 16'hffff;
            if (c_state[C_END]) begin
                atag_wen[cacop_wr_way] = cacop_need_clear;
                atag_wdata = 0;
            end
        end else if (refill_valid) begin
            adirty_wen = 1;
            adirty_wen_way = refill_way;
            adirty_index = refill_addr.index;
            adirty_wdata = 0;
            atag_wen[refill_way] = 1;
            atag_index = refill_addr.index;
            atag_wdata = {1'b1, refill_addr.tag};
            adata_index = {4{refill_addr.index}};
            adata_wen[refill_way] = 16'hffff;
            adata_wdata = refill_data;
        end else if (refill_working && ~refill_finish) begin
            adirty_ren = 1;
            adirty_index = s2_phy_addr.index;
            atag_index = s2_phy_addr.index;
            atag_ren[evict_way] = 1;
            adata_index = {4{s2_phy_addr.index}};
            adata_ren[evict_way] = 4'b1111;
        end else begin
            if ((hit_working || refill_finish) && s2_is_write) begin
                adirty_index = s2_phy_addr.index;
                adirty_wen = 1;
                adirty_wen_way = refill_finish ? refill_way : s2_hit_way;
                adirty_wdata = 1;
                adata_index[s2_phy_addr.word] = s2_phy_addr.index;
                adata_wen[refill_finish?refill_way : s2_hit_way][s2_phy_addr.word] = s2_write_strb;
                adata_wdata = {4{s2_write_data}};
            end
            if (pl2.input_next) begin
                atag_index = s1_virt_addr.index;
                atag_ren   = `CACHE_WAY'hf;
                if (~s1_is_write && ~s1_s2_conflict) begin
                    adata_index[s1_virt_addr.word] = s1_virt_addr.index;
                    for (int i = 0; i < 4; i++) adata_ren[i][s1_virt_addr.word] = 1;
                end
            end
        end
        for (int i = 0; i < `CACHE_WAY; i = i + 1) begin
            for (int j = 0; j < 4; j = j + 1) adata_ren[i][j] = adata_ren[i][j] || adata_wen[i][j];
        end
    end

    index_t aarray_init_addr;
    initial begin
        aarray_init_addr = 0;
    end
    always @(posedge clk) begin
        aarray_init_addr <= aarray_init_addr + 1;
    end
    cache_tag_mem_256x21 tag_array[`CACHE_WAY] (
        .clka (clk),
        .addra(rst ? aarray_init_addr : atag_index),
        .ena  ({`CACHE_WAY{rst}} | atag_ren | atag_wen),
        .douta(s2_read_tag),
        .wea  ({`CACHE_WAY{rst}} | atag_wen),
        .dina (rst ? {(`TAG_LEN + 1) {1'b0}} : atag_wdata)
    );
    cache_bank_mem_256x32 bank_array[`CACHE_WAY][4] (
        .clka (clk),
        .addra({4{adata_index}}),
        .ena  (adata_ren),
        .douta(s2_read_data),
        .wea  (adata_wen),
        .dina ({4{adata_wdata}})
    );
    cache_dirty_mem_1024x1 dirty_array (
        .clka (clk),
        .ena  (adirty_ren | adirty_wen),
        .wea  (adirty_wen),
        .addra(adirty_wen ? {adirty_index, adirty_wen_way} : adirty_index),
        .dina (adirty_wdata),
        .douta(s2_read_dirty)
    );
endmodule
`default_nettype none
