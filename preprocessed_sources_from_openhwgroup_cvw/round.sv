///////////////////////////////////////////
// round.sv
//
// Written: me@KatherineParry.com
// Modified: 7/5/2022
//
// Purpose: Rounder
//
// Documentation: RISC-V System on Chip Design
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwgroup/cvw
//
// Copyright (C) 2021-23 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file
// except in compliance with the License, or, at your option, the Apache License version 2.0. You
// may obtain a copy of the License at
//
// https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work distributed under the
// License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
// either express or implied. See the License for the specific language governing permissions
// and limitations under the License.
////////////////////////////////////////////////////////////////////////////////////////////////

module round (
  input  logic [  FMTBITS-1:0]     OutFmt,             // output format
  input  logic [2:0]               Frm,                // rounding mode
  input  logic [1:0]               PostProcSel,        // select the postprocessor output
  input  logic                     Ms,                 // normalized sign
  input  logic [  NORMSHIFTSZ-1:0] Mf,                 // normalized fraction
  // fma
  input  logic                     FmaOp,              // is an fma operation being done?
  input  logic [  NE+1:0]          FmaMe,              // exponent of the normalized sum for fma
  input  logic                     FmaASticky,         // addend's sticky bit
  // divsqrt
  input  logic                     DivOp,              // is a division operation being done
  input  logic                     DivSticky,          // divsqrt sticky bit
  input  logic [  NE+1:0]          Ue,                 // the divsqrt calculated exponent
  // cvt
  input  logic                     CvtOp,              // is a convert operation being done
  input  logic                     ToInt,              // is the cvt op a cvt to integer
  input  logic                     CvtResSubnormUf,    // is the cvt result subnormal or underflow
  input  logic                     CvtResUf,           // does the cvt result underflow
  input  logic [  NE:0]            CvtCe,              // the cvt calculated exponent
  // outputs
  output logic [  NE+1:0]          Me,                 // normalied fraction
  output logic                     UfPlus1,            // do you add one to the result if given an unbounded exponent
  output logic [  NE+1:0]          FullRe,             // Re with bits to determine sign and overflow
  output logic [  NE-1:0]          Re,                 // Result exponent
  output logic [  NF-1:0]          Rf,                 // Result fractionNormS
  output logic                     Sticky,             // sticky bit
  output logic                     Plus1,              // do you add one to the final result
  output logic                     Round, Guard        // bits needed to calculate rounding
);

  logic                            UfCalcPlus1;        // calculated plus one for unbounded exponent
  logic                            NormSticky;         // normalized sum's sticky bit
  logic [  NF-1:0]                 RoundFrac;          // rounded fraction
  logic                            FpRes;              // is the result a floating point
  logic                            IntRes;             // is the result an integer
  logic                            FpGuard, FpRound;   // floating point round/guard bits
  logic                            FpLsbRes;           // least significant bit of floating point result
  logic                            LsbRes;             // lsb of result
  logic                            CalcPlus1;          // calculated plus1
  logic                            FpPlus1;            // do you add one to the fp result
  logic [  FLEN:0]                 RoundAdd;           // how much to add to the result
  logic                            CvtToInt;           // Convert to integer operation

// what position is XLEN in?
//  options:
//     1: XLEN > NF   > NF1
//     2: NF   > XLEN > NF1
//     3: NF   > NF1  > XLEN
//  single and double will always be smaller than XLEN
//`define XLENPOS ((`XLEN>`NF) ? 1 : (`XLEN>`NF1) ? 2 : 3)
  localparam XLENPOS =   XLEN >   NF ? 1 :   XLEN >   NF1 ? 2 : 3;

  ///////////////////////////////////////////////////////////////////////////////
  // Rounding
  ///////////////////////////////////////////////////////////////////////////////

  // round to nearest even
  //      {Round, Sticky}
  //      0x - do nothing
  //      10 - tie - Plus1 if result is odd  (LSBNormSum = 1)
  //         - don't add 1 if a small number was supposed to be subtracted
  //      11 - do nothing if a small number was supposed to subtracted (the sticky bit was set by the small number)
  //         - plus 1 otherwise

  //  round to zero - subtract 1 if a small number was supposed to be subtracted from a positive result with guard and round bits of 0

  //  round to -infinity
  //          - Plus1 if negative unless a small number was supposed to be subtracted from a result with guard and round bits of 0
  //          - subtract 1 if a small number was supposed to be subtracted from a positive result with guard and round bits of 0

  //  round to infinity
  //          - Plus1 if positive unless a small number was supposed to be subtracted from a result with guard and round bits of 0
  //          - subtract 1 if a small number was supposed to be subtracted from a negative result with guard and round bits of 0

  //  round to nearest max magnitude
  //      {Guard, Round, Sticky}
  //      0x - do nothing
  //      10 - tie - Plus1
  //         - don't add 1 if a small number was supposed to be subtracted
  //      11 - do nothing if a small number was supposed to subtracted (the sticky bit was set by the small number)
  //         - Plus 1 otherwise

  // determine what format the final result is in: int or fp
  assign IntRes = ToInt;
  assign FpRes  = ~IntRes;
  assign CvtToInt = ToInt; // under current encodings, CvtOp always is 1 when ToInt is selected, so leave it out

  // sticky bit calculation
  if (  FPSIZES == 1) begin

      //     1: XLEN > NF
      //      |         XLEN          |
      //      |    NF     |1|1|
      //                     ^    ^ if floating point result
      //                     ^ if not an FMA result
      if (XLENPOS == 1)assign NormSticky = (|Mf[  NORMSHIFTSZ-  NF-2:  NORMSHIFTSZ-  XLEN-1]&FpRes)  |
                                                (|Mf[  NORMSHIFTSZ-  XLEN-2:0]);
      //     2: NF > XLEN
      if (XLENPOS == 2)assign NormSticky = (|Mf[  NORMSHIFTSZ-  XLEN-2:  NORMSHIFTSZ-  NF-1]&IntRes) |
                                                (|Mf[  NORMSHIFTSZ-  NF-2:0]);

  end else if (  FPSIZES == 2) begin
      // XLEN is either 64 or 32
      // so half and single are always smaller then XLEN

      // 1: XLEN > NF   > NF1
      if (XLENPOS == 1) assign NormSticky = (|Mf[  NORMSHIFTSZ-  NF1-2:  NORMSHIFTSZ-  NF-1]&FpRes&~OutFmt) |
                                                (|Mf[  NORMSHIFTSZ-  NF-2:  NORMSHIFTSZ-  XLEN-1]&FpRes) |
                                                (|Mf[  NORMSHIFTSZ-  XLEN-2:0]);
      // 2: NF   > XLEN > NF1
      if (XLENPOS == 2) assign NormSticky = (|Mf[  NORMSHIFTSZ-  NF1-2:  NORMSHIFTSZ-  XLEN-1]&FpRes&~OutFmt) |
                                                (|Mf[  NORMSHIFTSZ-  XLEN-2:  NORMSHIFTSZ-  NF-1]&(IntRes|~OutFmt)) |
                                                (|Mf[  NORMSHIFTSZ-  NF-2:0]);
      // 3: NF   > NF1  > XLEN
      if (XLENPOS == 3) assign NormSticky = (|Mf[  NORMSHIFTSZ-  XLEN-2:  NORMSHIFTSZ-  NF1-1]&IntRes) |
                                                (|Mf[  NORMSHIFTSZ-  NF1-2:  NORMSHIFTSZ-  NF-1]&(~OutFmt|IntRes)) |
                                                (|Mf[  NORMSHIFTSZ-  NF-2:0]);

  end else if (  FPSIZES == 3) begin
      // 1: XLEN > NF   > NF1
      if (XLENPOS == 1) assign NormSticky = (|Mf[  NORMSHIFTSZ-  NF2-2:  NORMSHIFTSZ-  NF1-1]&FpRes&(OutFmt==  FMT2)) |
                                                (|Mf[  NORMSHIFTSZ-  NF1-2:  NORMSHIFTSZ-  NF-1]&FpRes&~(OutFmt==  FMT)) |
                                                (|Mf[  NORMSHIFTSZ-  NF-2:  NORMSHIFTSZ-  XLEN-1]&FpRes) |
                                                (|Mf[  NORMSHIFTSZ-  XLEN-2:0]);
      // 2: NF   > XLEN > NF1
      if (XLENPOS == 2) assign NormSticky = (|Mf[  NORMSHIFTSZ-  NF2-2:  NORMSHIFTSZ-  NF1-1]&FpRes&(OutFmt==  FMT2)) |
                                                (|Mf[  NORMSHIFTSZ-  NF1-2:  NORMSHIFTSZ-  XLEN-1]&FpRes&~(OutFmt==  FMT)) |
                                                (|Mf[  NORMSHIFTSZ-  XLEN-2:  NORMSHIFTSZ-  NF-1]&(IntRes|~(OutFmt==  FMT))) |
                                                (|Mf[  NORMSHIFTSZ-  NF-2:0]);
      // 3: NF   > NF1  > XLEN
      if (XLENPOS == 3) assign NormSticky = (|Mf[  NORMSHIFTSZ-  NF2-2:  NORMSHIFTSZ-  XLEN-1]&FpRes&(OutFmt==  FMT2)) |
                                                (|Mf[  NORMSHIFTSZ-  XLEN-2:  NORMSHIFTSZ-  NF1-1]&((OutFmt==  FMT2)|IntRes)) |
                                                (|Mf[  NORMSHIFTSZ-  NF1-2:  NORMSHIFTSZ-  NF-1]&(~(OutFmt==  FMT)|IntRes)) |
                                                (|Mf[  NORMSHIFTSZ-  NF-2:0]);

  end else if (  FPSIZES == 4) begin
      // Quad precision will always be greater than XLEN
      // 2: NF   > XLEN > NF1
      if (XLENPOS == 2) assign NormSticky = (|Mf[  NORMSHIFTSZ-  H_NF-2:  NORMSHIFTSZ-  S_NF-1]&FpRes&(OutFmt==  H_FMT)) |
                                                (|Mf[  NORMSHIFTSZ-  S_NF-2:  NORMSHIFTSZ-  D_NF-1]&FpRes&((OutFmt==  S_FMT)|(OutFmt==  H_FMT))) |
                                                (|Mf[  NORMSHIFTSZ-  D_NF-2:  NORMSHIFTSZ-  XLEN-1]&FpRes&~(OutFmt==  Q_FMT)) |
                                                (|Mf[  NORMSHIFTSZ-  XLEN-2:  NORMSHIFTSZ-  Q_NF-1]&(~(OutFmt==  Q_FMT)|IntRes)) |
                                                (|Mf[  NORMSHIFTSZ-  Q_NF-2:0]);
      // 3: NF   > NF1  > XLEN
      // The extra XLEN bit will be ored later when calculating the final sticky bit - the ufplus1 not needed for integer
      if (XLENPOS == 3) assign NormSticky = (|Mf[  NORMSHIFTSZ-  H_NF-2:  NORMSHIFTSZ-  S_NF-1]&FpRes&(OutFmt==  H_FMT)) |
                                                (|Mf[  NORMSHIFTSZ-  S_NF-2:  NORMSHIFTSZ-  XLEN-1]&FpRes&((OutFmt==  S_FMT)|(OutFmt==  H_FMT))) |
                                                (|Mf[  NORMSHIFTSZ-  XLEN-2:  NORMSHIFTSZ-  D_NF-1]&((OutFmt==  S_FMT)|(OutFmt==  H_FMT)|IntRes)) |
                                                (|Mf[  NORMSHIFTSZ-  D_NF-2:  NORMSHIFTSZ-  Q_NF-1]&(~(OutFmt==  Q_FMT)|IntRes)) |
                                                (|Mf[  NORMSHIFTSZ-  Q_NF-2:0]);

  end

  // only add the Addend sticky if doing an FMA operation
  //      - the shifter shifts too far left when there's an underflow (shifting out all possible sticky bits)
  assign Sticky = FmaASticky&FmaOp | NormSticky | CvtResUf&CvtOp | FmaMe[  NE+1]&FmaOp | DivSticky&DivOp;

  // determine round and LSB of the rounded value
  //      - underflow round bit is used to determint the underflow flag
  if (  FPSIZES == 1) begin
      assign FpGuard  = Mf[  NORMSHIFTSZ-  NF-1];
      assign FpLsbRes = Mf[  NORMSHIFTSZ-  NF];
      assign FpRound  = Mf[  NORMSHIFTSZ-  NF-2];

  end else if (  FPSIZES == 2) begin
      assign FpGuard  = OutFmt ? Mf[  NORMSHIFTSZ-  NF-1] : Mf[  NORMSHIFTSZ-  NF1-1];
      assign FpLsbRes = OutFmt ? Mf[  NORMSHIFTSZ-  NF] : Mf[  NORMSHIFTSZ-  NF1];
      assign FpRound  = OutFmt ? Mf[  NORMSHIFTSZ-  NF-2] : Mf[  NORMSHIFTSZ-  NF1-2];

  end else if (  FPSIZES == 3) begin
      always_comb
          case (OutFmt)
                FMT: begin
                  FpGuard  = Mf[  NORMSHIFTSZ-  NF-1];
                  FpLsbRes = Mf[  NORMSHIFTSZ-  NF];
                  FpRound  = Mf[  NORMSHIFTSZ-  NF-2];
              end
                FMT1: begin
                  FpGuard  = Mf[  NORMSHIFTSZ-  NF1-1];
                  FpLsbRes = Mf[  NORMSHIFTSZ-  NF1];
                  FpRound  = Mf[  NORMSHIFTSZ-  NF1-2];
              end
                FMT2: begin
                  FpGuard  = Mf[  NORMSHIFTSZ-  NF2-1];
                  FpLsbRes = Mf[  NORMSHIFTSZ-  NF2];
                  FpRound  = Mf[  NORMSHIFTSZ-  NF2-2];
              end
              default: begin
                  FpGuard  = 1'bx;
                  FpLsbRes = 1'bx;
                  FpRound  = 1'bx;
              end
          endcase
  end else if (  FPSIZES == 4) begin
      always_comb
          case (OutFmt)
              2'h3: begin
                  FpGuard  = Mf[  NORMSHIFTSZ-  Q_NF-1];
                  FpLsbRes = Mf[  NORMSHIFTSZ-  Q_NF];
                  FpRound  = Mf[  NORMSHIFTSZ-  Q_NF-2];
              end
              2'h1: begin
                  FpGuard  = Mf[  NORMSHIFTSZ-  D_NF-1];
                  FpLsbRes = Mf[  NORMSHIFTSZ-  D_NF];
                  FpRound  = Mf[  NORMSHIFTSZ-  D_NF-2];
              end
              2'h0: begin
                  FpGuard  = Mf[  NORMSHIFTSZ-  S_NF-1];
                  FpLsbRes = Mf[  NORMSHIFTSZ-  S_NF];
                  FpRound  = Mf[  NORMSHIFTSZ-  S_NF-2];
              end
              2'h2: begin
                  FpGuard  = Mf[  NORMSHIFTSZ-  H_NF-1];
                  FpLsbRes = Mf[  NORMSHIFTSZ-  H_NF];
                  FpRound  = Mf[  NORMSHIFTSZ-  H_NF-2];
              end
          endcase
  end

  assign Guard  = CvtToInt ? Mf[  NORMSHIFTSZ-  XLEN-1] : FpGuard;
  assign LsbRes = CvtToInt ? Mf[  NORMSHIFTSZ-  XLEN] : FpLsbRes;
  assign Round  = CvtToInt ? Mf[  NORMSHIFTSZ-  XLEN-2] : FpRound;

  always_comb begin
      // Determine if you add 1
      case (Frm)
          3'b000: CalcPlus1  = Guard & (Round|Sticky|LsbRes);//round to nearest even
          3'b001: CalcPlus1  = 1'b0;//round to zero
          3'b010: CalcPlus1  = Ms;//round down
          3'b011: CalcPlus1  = ~Ms;//round up
          3'b100: CalcPlus1  = Guard;//round to nearest max magnitude
          default: CalcPlus1 = 1'bx;
      endcase
      // Determine if you add 1 (for underflow flag)
      case (Frm)
          3'b000: UfCalcPlus1  = Round & (Sticky|Guard);//round to nearest even
          3'b001: UfCalcPlus1  = 1'b0;//round to zero
          3'b010: UfCalcPlus1  = Ms;//round down
          3'b011: UfCalcPlus1  = ~Ms;//round up
          3'b100: UfCalcPlus1  = Round;//round to nearest max magnitude
          default: UfCalcPlus1 = 1'bx;
      endcase

  end

  // If an answer is exact don't round
  assign Plus1   = CalcPlus1 & (Sticky|Round|Guard);
  assign FpPlus1 = Plus1&~(CvtToInt);
  assign UfPlus1 = UfCalcPlus1 & (Sticky|Round);

  // place Plus1 into the proper position for the format
  if (  FPSIZES == 1) begin
      assign RoundAdd = {{  FLEN{1'b0}}, FpPlus1};

  end else if (  FPSIZES == 2) begin
      // \/FLEN+1
      //  | NE+2 |        NF      |
      //  '-NE+2-^----NF1----^
      //   FLEN+1-  NE-2-  NF1 = FLEN-1-NE-NF1
      assign RoundAdd = {(  NE+1+  NF1)'(0), FpPlus1&~OutFmt, (  NF-  NF1-1)'(0), FpPlus1&OutFmt};

  end else if (  FPSIZES == 3) begin
      assign RoundAdd = {(  NE+1+  NF2)'(0), FpPlus1&(OutFmt==  FMT2), (  NF1-  NF2-1)'(0), FpPlus1&(OutFmt==  FMT1), (  NF-  NF1-1)'(0), FpPlus1&(OutFmt==  FMT)};

  end else if (  FPSIZES == 4)
      assign RoundAdd = {(  Q_NE+1+  H_NF)'(0), FpPlus1&(OutFmt==  H_FMT), (  S_NF-  H_NF-1)'(0), FpPlus1&(OutFmt==  S_FMT), (  D_NF-  S_NF-1)'(0), FpPlus1&(OutFmt==  D_FMT), (  Q_NF-  D_NF-1)'(0), FpPlus1&(OutFmt==  Q_FMT)};

  // trim unneeded bits from fraction
  assign RoundFrac = Mf[  NORMSHIFTSZ-1:  NORMSHIFTSZ-  NF];

  // select the exponent
  always_comb
      case(PostProcSel)
          2'b10:    Me = FmaMe; // fma
          2'b00:    Me = {CvtCe[  NE], CvtCe}&{  NE+2{~CvtResSubnormUf|CvtResUf}}; // cvt
          // 2'b01: Me = DivDone ? Ue : 0; // divide
          2'b01:    Me = Ue; // divide
          default:  Me = '0;
      endcase

  // round the result
  //      - if the fraction overflows one should be added to the exponent
  assign {FullRe, Rf} = {Me, RoundFrac} + RoundAdd;
  assign Re           = FullRe[  NE-1:0];

endmodule
