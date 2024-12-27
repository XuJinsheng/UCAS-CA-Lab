
`include "common.svh"

`default_nettype none

module xjscpu_top (
    input wire clk,
    input wire rst,

    request_interface.sender memory_read_req[4],
    data_transfer_interface.receiver memory_read_data[4],
    request_interface.sender memory_write_req[2],
    data_transfer_interface.sender memory_write_data[2],
    output wire [69:0] debug_inst_retire
);
    rob_id_t next_retire_inst_id;
    flush_pipeline_interface flush_pipeline ();

    fetch_decode_interface fetch2decode ();
    predictor_fetch_interface predictor2fetch ();
    bru_predictor_interface bru2predictor ();
    CSR_ROB_fetch_interface CSR2fetch ();
    cache_TLB_interface cache2TLB[2] ();
    fetch_unit IFU (
        .clk(clk),
        .rst(rst),
        .memory_read_req(memory_read_req[0:1]),
        .memory_read_data(memory_read_data[0:1]),
        .decoder(fetch2decode),
        .predictor(predictor2fetch),
        .CSR(CSR2fetch),
        .TLB(cache2TLB[0]),
        .flush_pipeline(flush_pipeline)
    );
    predict_unit BPU (
        .clk  (clk),
        .rst  (rst),
        .fetch(predictor2fetch),
        .bru  (bru2predictor)
    );

    decode_rename_rob_dispatch_interface decode2dispatch ();
    rob_rename_interface rob2rename ();
    commit_rob_interface execute2commit[4] ();
    data_write_interface #(6, 1) rename2readytable ();
    exception_throw_interface throw_exception[2] ();
    CSR_ROB_interface csr2rob ();
    decode_unit decoder (
        .clk(clk),
        .rst(rst),
        .ifetch(fetch2decode),
        .dispatch(decode2dispatch),
        .flush_pipeline(flush_pipeline)
    );
    rename_unit rename (
        .clk(clk),
        .rst(rst),
        .decoder(decode2dispatch),
        .rob(rob2rename),
        .readytable(rename2readytable),
        .flush_pipeline(flush_pipeline)
    );
    reorder_buffer rob (
        .clk(clk),
        .rst(rst),
        .decoder(decode2dispatch),
        .rename(rob2rename),
        .eu(execute2commit),
        .exception_raise(throw_exception),
        .flush_send(flush_pipeline),
        .CSR(csr2rob),
        .fetch(CSR2fetch),
        .next_retire_inst_id(next_retire_inst_id),
        .inst_reitre_tb(debug_inst_retire)
    );

    issue_execute_interface issue2execute_special[2] ();
    execute_commit_interface execute2commit_special[2] ();
    integer_block integerblock (
        .clk(clk),
        .rst(rst),
        .decode2dispatch(decode2dispatch),
        .ROB(execute2commit),
        .rename2readytable(rename2readytable),
        .issue2execute_special(issue2execute_special),
        .execute2commit_special(execute2commit_special),
        .flush_pipeline(flush_pipeline),
        .next_retire_inst_id(next_retire_inst_id),
        .bru2predictor(bru2predictor)
    );

    data_t mem2csr_badv_addr;
    memory_unit MMU (
        .clk(clk),
        .rst(rst),
        .memory_read_req(memory_read_req[2:3]),
        .memory_read_data(memory_read_data[2:3]),
        .memory_write_req(memory_write_req),
        .memory_write_data(memory_write_data),

        .in(issue2execute_special[0]),
        .out(execute2commit_special[0]),
        .throw(throw_exception[0]),

        .TLB(cache2TLB[1]),
        .flush_pipeline(flush_pipeline),
        .next_retire_inst_id(next_retire_inst_id),
        .csr_badv_addr(mem2csr_badv_addr)
    );
    CSR_TLB_interface csr2tlb ();
    CSR_unit csr (
        .clk(clk),
        .rst(rst),
        .execute_in(issue2execute_special[1]),
        .execute_out(execute2commit_special[1]),
        .execute_throw(throw_exception[1]),
        .execute_flush(flush_pipeline),
        .ifetch(CSR2fetch),
        .ROB(csr2rob),
        .TLB(csr2tlb),
        .cache(cache2TLB),
        .mem_unit_badv_addr(mem2csr_badv_addr)
    );
    TLB_unit TLB (
        .clk  (clk),
        .rst  (rst),
        .CSR  (csr2tlb),
        .cache(cache2TLB)
    );
endmodule



module integer_block (
    input wire clk,
    input wire rst,
    decode_rename_rob_dispatch_interface.dispatch decode2dispatch,
    commit_rob_interface.commit ROB[4],
    data_write_interface.data_array rename2readytable,
    issue_execute_interface.issue issue2execute_special[2],
    execute_commit_interface execute2commit_special[2],
    flush_pipeline_interface.pipeline flush_pipeline,
    input wire rob_id_t next_retire_inst_id,
    bru_predictor_interface.BRU bru2predictor
);
    data_read_interface #(6, 1) readytable_read[10] ();
    data_write_interface #(6, 1) readytable_write[5] ();
    reg_file #(6, 1, 10, 5, 1) readytable (
        .clk  (clk),
        .rst  (rst),
        .read (readytable_read),
        .write(readytable_write)
    );
    assign readytable_write[4].wen  = rename2readytable.wen;
    assign readytable_write[4].addr = rename2readytable.addr;
    assign readytable_write[4].data = rename2readytable.data;
    data_read_interface regfile_read[10] ();
    data_write_interface regfile_write[4] ();
    reg_file #(6, 32, 10, 4, 0) regfile (
        .clk  (clk),
        .rst  (rst),
        .read (regfile_read),
        .write(regfile_write)
    );

    dispatch_issue_interface dispatch2issue[5] ();
    issue_execute_interface issue2execute[3] ();
    execute_commit_interface execute2commit[3] ();
    wakeup_interface wakeups[4] ();
    dispatch_unit dispatch (
        .clk(clk),
        .rst(rst),
        .readytable_read(readytable_read),
        .decoder(decode2dispatch),
        .issue(dispatch2issue),
        .flush_pipeline(flush_pipeline),
        .next_retire_inst_id(next_retire_inst_id)
    );
    issue_cluster alu_cluster (
        .clk(clk),
        .rst(rst),
        .regfile_read(regfile_read[0:1]),
        .dispatch(dispatch2issue[0]),
        .execute(issue2execute[0]),
        .bypass(execute2commit[0]),
        .wakeup_receive(wakeups),
        .flush_pipeline(flush_pipeline)
    );
    issue_cluster mdu_cluster (
        .clk(clk),
        .rst(rst),
        .regfile_read(regfile_read[2:3]),
        .dispatch(dispatch2issue[1]),
        .execute(issue2execute[1]),
        .bypass(execute2commit[1]),
        .wakeup_receive(wakeups),
        .flush_pipeline(flush_pipeline)
    );
    issue_cluster bru_cluster (
        .clk(clk),
        .rst(rst),
        .regfile_read(regfile_read[4:5]),
        .dispatch(dispatch2issue[2]),
        .execute(issue2execute[2]),
        .bypass(execute2commit[2]),
        .wakeup_receive(wakeups),
        .flush_pipeline(flush_pipeline)
    );
    issue_cluster mmu_cluster (
        .clk(clk),
        .rst(rst),
        .regfile_read(regfile_read[6:7]),
        .dispatch(dispatch2issue[3]),
        .execute(issue2execute_special[0]),
        .bypass(execute2commit_special[0]),
        .wakeup_receive(wakeups),
        .flush_pipeline(flush_pipeline)
    );
    issue_cluster csr_cluster (
        .clk(clk),
        .rst(rst),
        .regfile_read(regfile_read[8:9]),
        .dispatch(dispatch2issue[4]),
        .execute(issue2execute_special[1]),
        .bypass(execute2commit_special[1]),
        .wakeup_receive(wakeups),
        .flush_pipeline(flush_pipeline)
    );

    commit_unit alu_commit (
        .clk(clk),
        .rst(rst),
        .regfile_write(regfile_write[0]),
        .readytable_write(readytable_write[0]),
        .execute(execute2commit[0]),
        .ROB(ROB[0]),
        .wakeup_send(wakeups[0])
    );
    commit_unit mdu_commit (
        .clk(clk),
        .rst(rst),
        .regfile_write(regfile_write[1]),
        .readytable_write(readytable_write[1]),
        .execute(execute2commit[1]),
        .ROB(ROB[1]),
        .wakeup_send(wakeups[1])
    );
    commit_unit2 csr_bru_commit (
        .clk(clk),
        .rst(rst),
        .regfile_write(regfile_write[2]),
        .readytable_write(readytable_write[2]),
        .execute0(execute2commit_special[1]),
        .execute1(execute2commit[2]),
        .ROB(ROB[2]),
        .wakeup_send(wakeups[2])
    );
    commit_unit mmu_commit (
        .clk(clk),
        .rst(rst),
        .regfile_write(regfile_write[3]),
        .readytable_write(readytable_write[3]),
        .execute(execute2commit_special[0]),
        .ROB(ROB[3]),
        .wakeup_send(wakeups[3])
    );
    alu_unit alu (
        .clk(clk),
        .rst(rst),
        .in(issue2execute[0]),
        .out(execute2commit[0]),
        .flush_pipeline(flush_pipeline)
    );
    muldiv_unit mdu (
        .clk(clk),
        .rst(rst),
        .in(issue2execute[1]),
        .out(execute2commit[1]),
        .flush_pipeline(flush_pipeline)
    );
    branch_unit bru (
        .clk(clk),
        .rst(rst),
        .in(issue2execute[2]),
        .out(execute2commit[2]),
        .predictor(bru2predictor),
        .flush_pipeline(flush_pipeline)
    );
endmodule

`default_nettype wire
