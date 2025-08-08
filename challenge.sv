/*

Put any submodules you need here.

You are not allowed to implement your own submodules or functions for the addition,
subtraction, multiplication, division, comparison or getting the square
root of floating-point numbers. For such operations you can only use the
modules from the arithmetic_block_wrappers directory.

*/

module challenge
(
    input                     clk,
    input                     rst,

    input                     arg_vld,
    input        [FLEN - 1:0] a,
    input        [FLEN - 1:0] b,
    input        [FLEN - 1:0] c,

    output logic              res_vld,
    output logic [FLEN - 1:0] res
);
    /*

    The Prompt:

    Finish the code of a pipelined block in the file challenge.sv. The block
    computes a formula "a ** 5 + 0.3 * b + c". You are not allowed to
    implement your own submodules or functions for the addition,
    subtraction, multiplication, division, comparison or getting the square
    root of floating-point numbers. For such operations you can only use the
    modules from the arithmetic_block_wrappers directory. You are not
    allowed to change any other files except challenge.sv. You can check the
    results by running the script "simulate". If the script outputs "FAIL"
    or does not output "PASS" from the code in the provided testbench.sv by
    running the provided script "simulate", your design is not working and
    is not an answer to the challenge. Your design must be able to accept a
    new set of the inputs (a, b and c) each clock cycle back-to-back and
    generate the computation results without any stalls and without
    requiring empty cycle gaps in the input. The solution code has to be
    synthesizable SystemVerilog RTL. A human should not help AI by tipping
    anything on latencies or handshakes of the submodules. The AI has to
    figure this out by itself by analyzing the code in the repository
    directories. Likewise a human should not instruct AI how to build a
    pipeline structure since it makes the exercise meaningless.

    */

    // ---------------------------------------------
    // Constants
    // ---------------------------------------------
    // 0.3 in IEEE-754
    localparam logic [FLEN-1:0] FP_CONST_0P3 =
        (FLEN == 64) ? 64'h3FD3333333333333 :
        (FLEN == 32) ? 32'h3E99999A : {FLEN{1'b0}}; // default 0 if unsupported FLEN

    // ---------------------------------------------
    // First pipeline: compute a^5 using three multipliers
    // m1 = a * a
    // m2 = m1 * m1 = a^4
    // m3 = m2 * a_d6 = a^5 (a delayed 6 cycles to align with m2)
    // ---------------------------------------------

    // m1: a * a
    logic [FLEN-1:0] m1_res;  logic m1_vld;
    f_mult u_m1 (
        .clk(clk), .rst(rst),
        .a(a), .b(a),
        .up_valid(arg_vld),
        .res(m1_res), .down_valid(m1_vld), .busy(), .error()
    );

    // m2: m1_res * m1_res
    logic [FLEN-1:0] m2_res;  logic m2_vld;
    f_mult u_m2 (
        .clk(clk), .rst(rst),
        .a(m1_res), .b(m1_res),
        .up_valid(m1_vld),
        .res(m2_res), .down_valid(m2_vld), .busy(), .error()
    );

    // Delay original 'a' by 6 cycles to align with m2 output valid
    localparam int DLY_A_TO_M3 = 6; // two mult stages x 3 cycles each
    logic [FLEN-1:0] a_pipe   [0:DLY_A_TO_M3-1];
    logic            a_vld_pipe[0:DLY_A_TO_M3-1];

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < DLY_A_TO_M3; i++) begin
                a_pipe[i]     <= '0;
                a_vld_pipe[i] <= 1'b0;
            end
        end else begin
            // Shift every cycle, insert current input with its valid
            a_pipe[0]     <= a;
            a_vld_pipe[0] <= arg_vld;
            for (int k = 1; k < DLY_A_TO_M3; k++) begin
                a_pipe[k]     <= a_pipe[k-1];
                a_vld_pipe[k] <= a_vld_pipe[k-1];
            end
        end
    end

    // m3: m2_res * a_d6
    logic [FLEN-1:0] m3_res;  logic m3_vld;
    f_mult u_m3 (
        .clk(clk), .rst(rst),
        .a(m2_res), .b(a_pipe[DLY_A_TO_M3-1]),
        .up_valid(m2_vld),
        .res(m3_res), .down_valid(m3_vld), .busy(), .error()
    );

    // ---------------------------------------------
    // Second pipeline: compute 0.3*b + c
    // mb = b * 0.3 (3 cycles), delay c by 3 cycles, then add (adder has 4-cycle latency)
    // Then delay this sum by 2 more cycles to align with a^5 (which is ready at 9 cycles)
    // ---------------------------------------------

    // mb: b * 0.3
    logic [FLEN-1:0] mb_res;  logic mb_vld;
    f_mult u_mb (
        .clk(clk), .rst(rst),
        .a(b), .b(FP_CONST_0P3),
        .up_valid(arg_vld),
        .res(mb_res), .down_valid(mb_vld), .busy(), .error()
    );

    // Delay c by 3 cycles to align with mb_res
    localparam int DLY_C_TO_ADD1 = 3; // f_mult latency
    logic [FLEN-1:0] c_pipe   [0:DLY_C_TO_ADD1-1];
    logic            c_vld_pipe[0:DLY_C_TO_ADD1-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < DLY_C_TO_ADD1; i++) begin
                c_pipe[i]     <= '0;
                c_vld_pipe[i] <= 1'b0;
            end
        end else begin
            c_pipe[0]     <= c;
            c_vld_pipe[0] <= arg_vld;
            for (int k = 1; k < DLY_C_TO_ADD1; k++) begin
                c_pipe[k]     <= c_pipe[k-1];
                c_vld_pipe[k] <= c_vld_pipe[k-1];
            end
        end
    end

    // add1: (0.3*b) + c_d3
    logic [FLEN-1:0] add1_res; logic add1_vld;
    f_add u_add1 (
        .clk(clk), .rst(rst),
        .a(mb_res), .b(c_pipe[DLY_C_TO_ADD1-1]),
        .up_valid(mb_vld),
        .res(add1_res), .down_valid(add1_vld), .busy(), .error()
    );

    // Delay add1 result by 2 cycles to align with a^5 at 9 cycles (add1 at 7)
    localparam int DLY_ADD1_TO_ADD2 = 2;
    logic [FLEN-1:0] add1_pipe   [0:DLY_ADD1_TO_ADD2-1];
    logic            add1_vld_pipe[0:DLY_ADD1_TO_ADD2-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < DLY_ADD1_TO_ADD2; i++) begin
                add1_pipe[i]     <= '0;
                add1_vld_pipe[i] <= 1'b0;
            end
        end else begin
            add1_pipe[0]     <= add1_res;
            add1_vld_pipe[0] <= add1_vld;
            for (int k = 1; k < DLY_ADD1_TO_ADD2; k++) begin
                add1_pipe[k]     <= add1_pipe[k-1];
                add1_vld_pipe[k] <= add1_vld_pipe[k-1];
            end
        end
    end

    // ---------------------------------------------
    // Final adder: a^5 + (0.3*b + c)
    // Inputs aligned so that up_valid can be either stream's valid; use AND for safety
    // ---------------------------------------------

    logic add2_up_valid;
    assign add2_up_valid = m3_vld & add1_vld_pipe[DLY_ADD1_TO_ADD2-1];

    logic [FLEN-1:0] add2_res; logic add2_vld;
    f_add u_add2 (
        .clk(clk), .rst(rst),
        .a(m3_res), .b(add1_pipe[DLY_ADD1_TO_ADD2-1]),
        .up_valid(add2_up_valid),
        .res(add2_res), .down_valid(add2_vld), .busy(), .error()
    );

    // Outputs
    always_ff @(posedge clk) begin
        if (rst) begin
            res     <= '0;
            res_vld <= 1'b0;
        end else begin
            res     <= add2_res;
            res_vld <= add2_vld;
        end
    end

endmodule
