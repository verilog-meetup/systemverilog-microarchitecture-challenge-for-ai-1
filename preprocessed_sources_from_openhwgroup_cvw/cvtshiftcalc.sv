///////////////////////////////////////////
// cvtshiftcalc.sv
//
// Written: me@KatherineParry.com
// Modified: 7/5/2022
//
// Purpose: Conversion shift calculation
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

module cvtshiftcalc (
  input  logic                     XZero,              // is the input zero?
  input  logic                     ToInt,              // to integer conversion?
  input  logic                     IntToFp,            // integer to floating point conversion?
  input  logic [  FMTBITS-1:0]     OutFmt,             // output format
  input  logic [  NE:0]            CvtCe,              // the calculated exponent
  input  logic [  NF:0]            Xm,                 // input mantissas
  input  logic [  CVTLEN-1:0]      CvtLzcIn,           // input to the Leading Zero Counter (without msb)
  input  logic                     CvtResSubnormUf,    // is the conversion result subnormal or underflows
  output logic                     CvtResUf,           // does the cvt result unerflow
  output logic [  CVTLEN+  NF:0]   CvtShiftIn          // number to be shifted
);

  logic [$clog2(  NF):0]           ResNegNF;           // the result's fraction length negated (-NF)

  ///////////////////////////////////////////////////////////////////////////
  // shifter
  ///////////////////////////////////////////////////////////////////////////

  // seclect the input to the shifter
  //      fp  -> int:
  //          |    XLEN  zeros |     mantissa      | 0's if necessary |
  //                          .
  //          Other problems:
  //              - if shifting to the right (neg CalcExp) then don't a 1 in the round bit (to prevent an incorrect plus 1 later during rounding)
  //              - we do however want to keep the one in the sticky bit so set one of bits in the sticky bit area to 1
  //                  - ex: for the case 0010000.... (double)
  //      ??? -> fp:
  //          - if result is subnormal or underflowed then we want to shift right i.e. shift right then shift left:
  //              |    NF-1  zeros   |     mantissa      | 0's if necessary |
  //              .
  //          - otherwise:
  //              |      LzcInM      |  0's if necessary |
  //              .
  // change to int shift to the left one
  always_comb
  //                                                        get rid of round bit if needed
  //                                                        |                    add sticky bit if needed
  //                                                        |                    |
      if (ToInt)                CvtShiftIn = {{  XLEN{1'b0}}, Xm[  NF]&~CvtCe[  NE], Xm[  NF-1]|(CvtCe[  NE]&Xm[  NF]), Xm[  NF-2:0], {  CVTLEN-  XLEN{1'b0}}};
      else if (CvtResSubnormUf) CvtShiftIn = {{  NF-1{1'b0}}, Xm, {  CVTLEN-  NF+1{1'b0}}};
      else                      CvtShiftIn = {CvtLzcIn, {  NF+1{1'b0}}};

  // choose the negative of the fraction size
  if (  FPSIZES == 1) begin
      assign ResNegNF = -($clog2(  NF)+1)'(  NF);

  end else if (  FPSIZES == 2) begin
      assign ResNegNF = OutFmt ? -($clog2(  NF)+1)'(  NF) : -($clog2(  NF)+1)'(  NF1);

  end else if (  FPSIZES == 3) begin
      always_comb
          case (OutFmt)
                FMT:  ResNegNF  = -($clog2(  NF)+1)'(  NF);
                FMT1: ResNegNF  = -($clog2(  NF)+1)'(  NF1);
                FMT2: ResNegNF  = -($clog2(  NF)+1)'(  NF2);
              default: ResNegNF = '0; // Not used for floating-point so don't care, but convert to unsigned long has OutFmt = 11.
          endcase

  end else if (  FPSIZES == 4) begin
      always_comb
          case (OutFmt)
              2'h3: ResNegNF = -($clog2(  NF)+1)'(  Q_NF);
              2'h1: ResNegNF = -($clog2(  NF)+1)'(  D_NF);
              2'h0: ResNegNF = -($clog2(  NF)+1)'(  S_NF);
              2'h2: ResNegNF = -($clog2(  NF)+1)'(  H_NF);
          endcase
  end

  // determine if the result underflows ??? -> fp
  //      - if the first 1 is shifted out of the result then the result underflows
  //      - can't underflow an integer to fp conversions
  assign CvtResUf = ($signed(CvtCe) < $signed({{  NE-$clog2(  NF){1'b1}}, ResNegNF}))&~XZero&~IntToFp;

endmodule
