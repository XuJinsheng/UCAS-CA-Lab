`default_nettype none

module mycpu_top (
    input  wire        aclk,
    input  wire        aresetn,
    // read req channel
    output wire [ 3:0] arid,              // 读请求ID
    output wire [31:0] araddr,            // 读请求地址
    output wire [ 7:0] arlen,             // 读请求传输长度（数据传输拍数）
    output wire [ 2:0] arsize,            // 读请求传输大小（数据传输每拍的字节数）
    output wire [ 1:0] arburst,           // 传输类型   
    output wire [ 1:0] arlock,            // 原子锁
    output wire [ 3:0] arcache,           // Cache属性
    output wire [ 2:0] arprot,            // 保护属性
    output wire        arvalid,           // 读请求地址有效
    input  wire        arready,           // 读请求地址握手信号
    // read response channel
    input  wire [ 3:0] rid,               // 读请求ID号，同一请求rid与arid一致
    input  wire [31:0] rdata,             // 读请求读出的数据
    input  wire [ 1:0] rresp,             // 读请求是否完成   
    input  wire        rlast,             // 读请求最后一拍数据的指示信号  
    input  wire        rvalid,            // 读请求数据有效
    output wire        rready,            // Master端准备好接受数据
    // write req channel
    output wire [ 3:0] awid,              // 写请求的ID号
    output wire [31:0] awaddr,            // 写请求的地址
    output wire [ 7:0] awlen,             // 写请求传输长度（拍数）
    output wire [ 2:0] awsize,            // 写请求传输每拍字节数
    output wire [ 1:0] awburst,           // 写请求传输类型
    output wire [ 1:0] awlock,            // 原子锁
    output wire [ 3:0] awcache,           // Cache属性
    output wire [ 2:0] awprot,            // 保护属性
    output wire        awvalid,           // 写请求地址有效
    input  wire        awready,           // Slave端准备好接受地址传输   
    // write data channel
    output wire [ 3:0] wid,               // 写请求的ID号
    output wire [31:0] wdata,             // 写请求的写数据
    output wire [ 3:0] wstrb,             // 写请求字节选通位
    output wire        wlast,             // 写请求的最后一拍数据的指示信号
    output wire        wvalid,            // 写数据有效
    input  wire        wready,            // Slave端准备好接受写数据传输   
    // write response channel
    input  wire [ 3:0] bid,               // 写请求的ID号           
    input  wire [ 1:0] bresp,             // 写请求完成信号         
    input  wire        bvalid,            // 写请求响应有效
    output wire        bready,            // Master端准备好接收响应信号
    // trace debug interface
    output wire [31:0] debug_wb_pc,
    output wire [ 3:0] debug_wb_rf_we,
    output wire [ 4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata
);
    reg reset;
    always @(posedge aclk) reset <= ~aresetn;
    wire debug_wb_rf_wen;
    assign debug_wb_rf_we = {4{debug_wb_rf_wen}};
    wire clk = aclk, rst = reset;


    request_interface cpu_read_req[4] ();
    data_transfer_interface cpu_read_data[4] ();
    request_interface cpu_write_req[2] ();
    data_transfer_interface cpu_write_data[2] ();


    xjscpu_top cpu (
        .clk(clk),
        .rst(rst),
        .memory_read_req(cpu_read_req),
        .memory_read_data(cpu_read_data),
        .memory_write_req(cpu_write_req),
        .memory_write_data(cpu_write_data),
        .debug_inst_retire({debug_wb_rf_wen, debug_wb_rf_wnum, debug_wb_rf_wdata, debug_wb_pc})
    );


    reg [31:0] last_write_addr;
    wire read_block = last_write_addr[31:4] == araddr[31:4];
    // read state machine
    localparam R_IDLE = 0, R_REQ = 1, R_RD = 2;
    reg [2:0] r_state, r_state_next;
    always @(posedge clk) begin
        if (rst) r_state <= 1 << R_IDLE;
        else r_state <= 1 << r_state_next;
    end
    reg [1:0] read_id;

    generate
        wire [3:0] arvalid_array;
        for (genvar i = 0; i < 4; i = i + 1) begin
            assign arvalid_array[i] = cpu_read_req[i].valid;
        end
    endgenerate
    always_comb begin
        case (r_state)
            1 << R_IDLE: r_state_next = (|arvalid_array) ? R_REQ : R_IDLE;
            1 << R_REQ: r_state_next = (arvalid && arready) ? R_RD : R_REQ;
            1 << R_RD: r_state_next = (rvalid && rready && rlast) ? R_IDLE : R_RD;
            default: r_state_next = R_IDLE;
        endcase
    end
    always @(posedge clk) begin
        if (r_state[R_IDLE]) begin
            for (int i = 3; i >= 0; i = i - 1) begin
                if (arvalid_array[i]) begin
                    read_id <= i;
                    break;
                end
            end
        end
    end
    // read request
    assign arid = read_id;
    assign arsize = 2;
    assign {arburst, arlock, arcache, arprot} = {2'b01, 2'b0, 4'b0, 3'b0};
    assign arvalid = r_state[R_REQ] && ~read_block;
    generate
        wire [3:0][31:0] araddr_array;
        wire [3:0][ 7:0] arlen_array;
        for (genvar i = 0; i < 4; i = i + 1) begin
            assign araddr_array[i] = cpu_read_req[i].addr;
            assign arlen_array[i] = cpu_read_req[i].len;
            assign cpu_read_req[i].ready = read_id == i && arready && r_state[R_REQ];
        end
        assign araddr = araddr_array[read_id];
        assign arlen  = arlen_array[read_id];
    endgenerate
    // read response
    generate
        wire [3:0] rready_array;
        for (genvar i = 0; i < 4; i = i + 1) begin
            assign cpu_read_data[i].valid = rid == i && rvalid && r_state[R_RD];
            assign cpu_read_data[i].last = rid == i && rlast;
            assign cpu_read_data[i].data = rdata;
            assign rready_array[i] = rid == i && cpu_read_data[i].ready;
        end
        assign rready = r_state[R_IDLE] || rready_array[rid];
    endgenerate


    // write state machine
    reg [1:0] write_id;
    localparam W_IDLE = 0, W_REQ = 1, W_WR = 2, W_END = 3;
    reg [3:0] w_state, w_state_next;
    always @(posedge clk) begin
        if (rst) w_state <= 1 << R_IDLE;
        else w_state <= 1 << w_state_next;
    end
    always_comb begin
        case (w_state)
            1 << W_IDLE: w_state_next = (cpu_write_req[0].valid || cpu_write_req[1].valid) ? W_REQ : W_IDLE;
            1 << W_REQ: w_state_next = (awvalid && awready) ? W_WR : W_REQ;
            1 << W_WR: w_state_next = (wvalid && wready && wlast) ? W_END : W_WR;
            1 << W_END: w_state_next = bvalid ? W_IDLE : W_END;
            default: w_state_next = W_IDLE;
        endcase
    end
    always @(posedge clk) begin
        if (rst) last_write_addr <= 0;
        else if (w_state[W_REQ]) last_write_addr <= awaddr;
        else if (w_state[W_IDLE]) last_write_addr <= 0;
    end
    always @(posedge clk) begin
        if (w_state[W_IDLE]) write_id <= cpu_write_req[1].valid ? 1 : 0;
    end
    // write request
    assign awid = write_id;
    assign awvalid = w_state[W_REQ];
    assign awsize = 2;
    assign {awburst, awlock, awcache, awprot} = {2'b01, 2'b0, 4'b0, 3'b0};
    generate
        wire [1:0][31:0] awaddr_array;
        wire [1:0][ 7:0] awlen_array;
        for (genvar i = 0; i < 2; i = i + 1) begin
            assign awaddr_array[i] = cpu_write_req[i].addr;
            assign awlen_array[i] = cpu_write_req[i].len;
            assign cpu_write_req[i].ready = write_id == i && awready && w_state[W_REQ];
        end
        assign awaddr = awaddr_array[write_id];
        assign awlen  = awlen_array[write_id];
    endgenerate

    // write data
    generate
        wire [1:0][31:0] wdata_array;
        wire [1:0][3:0] wstrb_array;
        wire [1:0] wlast_array;
        wire [1:0] wvalid_array;
        for (genvar i = 0; i < 2; i = i + 1) begin
            assign wdata_array[i] = cpu_write_data[i].data;
            assign wstrb_array[i] = cpu_write_data[i].wstrb;
            assign wlast_array[i] = cpu_write_data[i].last;
            assign wvalid_array[i] = cpu_write_data[i].valid;
            assign cpu_write_data[i].ready = write_id == i && wready && w_state[W_WR];
        end
        assign wid = write_id;
        assign wdata = wdata_array[write_id];
        assign wstrb = wstrb_array[write_id];
        assign wlast = wlast_array[write_id];
        assign wvalid = w_state[W_WR] && wvalid_array[write_id];
    endgenerate
    assign bready = w_state[W_IDLE] || w_state[W_END];

endmodule
`default_nettype wire
