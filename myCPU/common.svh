`ifndef XJS_INCLUDE_COMMON
`define XJS_INCLUDE_COMMON

typedef logic [31:0] data_t;
typedef logic [31:0] immediate_t;
typedef logic [4:0] arch_addr_t;
typedef logic [5:0] phy_addr_t;
typedef logic [5:0] uop_t;

typedef logic [6:0] rob_id_t;
function automatic logic compare_rob_age;
    input rob_id_t a, b;
    compare_rob_age = a[6] ^ b[6] ^ (a[5:0] < b[5:0]);
endfunction

typedef struct packed {
    rob_id_t   rob_id;
    phy_addr_t rd_phy;
} eu_inst_info;

typedef enum logic [4:0] {
    EXCEPTION_NONE = 0,
    EXCEPTION_INTERRUPT = 1,
    EXCEPTION_ERTN = 2,
    EXCEPTION_UNPRIVILEGE_INST = 3,
    EXCEPTION_UNSUPPORTED_INST = 4,
    EXCEPTION_SYSCALL = 5,
    EXCEPTION_BREAKPOINT = 6,
    EXCEPTION_FLUSHPIPELINE = 7,
    EXCEPTION_UNALIGNED = 8,
    EXCEPTION_TLB_REFILL = 9,
    EXCEPTION_LOAD_PAGE_FAULT = 10,
    EXCEPTION_STORE_PAGE_FAULT = 11,
    EXCEPTION_MODIFY_PAGE_FAULT = 12,
    EXCEPTION_PRIVILEGE_PAGE_FAULT = 13
} exception_t;

interface flush_pipeline_interface;
    logic flush;
    logic is_exception;
    rob_id_t rob_id;
    logic is_branch_failure;
    assign is_branch_failure = 0;
    assign flush = is_exception || is_branch_failure;
    modport ROB(output is_exception);
    modport pipeline(input flush, is_exception, rob_id);
endinterface

`include "tools.sv"
`endif
