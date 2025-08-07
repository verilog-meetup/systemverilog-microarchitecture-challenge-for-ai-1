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

    // Constants
    logic [FLEN - 1:0] const_0_3;
    assign const_0_3 = 64'h3FD3333333333333; // 0.3 in IEEE 754 double precision

    // Intermediate signals for multipliers
    logic [FLEN - 1:0] a_squared;
    logic              a_squared_vld;
    logic              a_squared_busy;

    logic [FLEN - 1:0] a_fourth;
    logic              a_fourth_vld;
    logic              a_fourth_busy;

    logic [FLEN - 1:0] a_fifth;
    logic              a_fifth_vld;
    logic              a_fifth_busy;

    logic [FLEN - 1:0] b_times_0_3;
    logic              b_times_0_3_vld;
    logic              b_times_0_3_busy;

    // Intermediate signals for adders
    logic [FLEN - 1:0] a5_plus_03b;
    logic              a5_plus_03b_vld;
    logic              a5_plus_03b_busy;

    // Pipeline registers to delay inputs as needed
    // For a^4 * a multiplication at cycle 6, we need 'a' from cycle 0
    logic [FLEN - 1:0] a_delayed [5:0];
    
    // For final addition at cycle 13, we need 'c' from cycle 0
    logic [FLEN - 1:0] c_delayed [12:0];
    
    // Delay 'a' for 6 cycles
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 6; i++) begin
                a_delayed[i] <= '0;
            end
        end else begin
            a_delayed[0] <= a;
            for (int i = 1; i < 6; i++) begin
                a_delayed[i] <= a_delayed[i-1];
            end
        end
    end

    // Delay 'c' for 13 cycles
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 13; i++) begin
                c_delayed[i] <= '0;
            end
        end else begin
            c_delayed[0] <= c;
            for (int i = 1; i < 13; i++) begin
                c_delayed[i] <= c_delayed[i-1];
            end
        end
    end

    // First multiplication: a * a = a^2 (3 cycles)
    f_mult mult_a_squared (
        .clk       (clk),
        .rst       (rst),
        .a         (a),
        .b         (a),
        .up_valid  (arg_vld),
        .res       (a_squared),
        .down_valid(a_squared_vld),
        .busy      (a_squared_busy),
        .error     ()
    );

    // Second multiplication: a^2 * a^2 = a^4 (3 more cycles, total 6)
    f_mult mult_a_fourth (
        .clk       (clk),
        .rst       (rst),
        .a         (a_squared),
        .b         (a_squared),
        .up_valid  (a_squared_vld),
        .res       (a_fourth),
        .down_valid(a_fourth_vld),
        .busy      (a_fourth_busy),
        .error     ()
    );

    // Third multiplication: a^4 * a = a^5 (3 more cycles, total 9)
    // Need 'a' from 6 cycles ago (when a_fourth is ready)
    f_mult mult_a_fifth (
        .clk       (clk),
        .rst       (rst),
        .a         (a_fourth),
        .b         (a_delayed[5]),  // a from 6 cycles ago
        .up_valid  (a_fourth_vld),
        .res       (a_fifth),
        .down_valid(a_fifth_vld),
        .busy      (a_fifth_busy),
        .error     ()
    );

    // Parallel multiplication: 0.3 * b (3 cycles)
    f_mult mult_b_0_3 (
        .clk       (clk),
        .rst       (rst),
        .a         (const_0_3),
        .b         (b),
        .up_valid  (arg_vld),
        .res       (b_times_0_3),
        .down_valid(b_times_0_3_vld),
        .busy      (b_times_0_3_busy),
        .error     ()
    );

    // Pipeline register to delay b*0.3 result to align with a^5
    // 0.3*b ready at cycle 3, a^5 ready at cycle 9, need 6 cycle delay
    logic [FLEN - 1:0] b_times_0_3_delayed [5:0];
    logic              b_times_0_3_vld_delayed [5:0];
    
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 6; i++) begin
                b_times_0_3_delayed[i] <= '0;
                b_times_0_3_vld_delayed[i] <= '0;
            end
        end else begin
            b_times_0_3_delayed[0] <= b_times_0_3;
            b_times_0_3_vld_delayed[0] <= b_times_0_3_vld;
            for (int i = 1; i < 6; i++) begin
                b_times_0_3_delayed[i] <= b_times_0_3_delayed[i-1];
                b_times_0_3_vld_delayed[i] <= b_times_0_3_vld_delayed[i-1];
            end
        end
    end

    // First addition: a^5 + 0.3*b (4 cycles, total 13)
    f_add add_a5_03b (
        .clk       (clk),
        .rst       (rst),
        .a         (a_fifth),
        .b         (b_times_0_3_delayed[5]),
        .up_valid  (a_fifth_vld),
        .res       (a5_plus_03b),
        .down_valid(a5_plus_03b_vld),
        .busy      (a5_plus_03b_busy),
        .error     ()
    );

    // Final addition: (a^5 + 0.3*b) + c (4 cycles, total 17)
    // Need 'c' from 13 cycles ago
    f_add add_final (
        .clk       (clk),
        .rst       (rst),
        .a         (a5_plus_03b),
        .b         (c_delayed[12]),  // c from 13 cycles ago
        .up_valid  (a5_plus_03b_vld),
        .res       (res),
        .down_valid(res_vld),
        .busy      (),
        .error     ()
    );

endmodule