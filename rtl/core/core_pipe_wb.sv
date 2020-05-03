
//
// module: core_pipe_wb
//
//  Writeback stage. Responsible for GPR writebacks, CSR accesses,
//  Load data processing, trap raising.
//
module core_pipe_wb (

input  wire                 g_clk           , // Global clock
input  wire                 g_resetn        , // Global active low sync reset.

output wire                 s3_cf_valid     , // Control flow change?
input  wire                 s3_cf_ack       , // Control flow acknwoledged
output wire [         XL:0] s3_cf_target    , // Control flow destination

input  wire                 s3_valid        , // New instruction ready
output wire                 s3_ready        , // WB ready for new instruciton.
input  wire                 s3_full         , // WB has an instr in it.
input  wire [         XL:0] s3_pc           , // Writeback stage PC
input  wire [         XL:0] s3_n_pc         , // Writeback stage next PC
input  wire [         31:0] s3_instr        , // Writeback stage instr word
input  wire [         XL:0] s3_wdata        , // Writeback stage instr word
input  wire [ REG_ADDR_R:0] s3_rd           , // Writeback stage instr word
input  wire [   LSU_OP_R:0] s3_lsu_op       , // Writeback LSU op
input  wire [   CSR_OP_R:0] s3_csr_op       , // Writeback CSR op
input  wire [         11:0] s3_csr_addr     , // CSR Address
input  wire [   CFU_OP_R:0] s3_cfu_op       , // Writeback CFU op
input  wire [    WB_OP_R:0] s3_wb_op        , // Writeback Data source.
input  wire                 s3_trap         , // Raise a trap

output wire                 s3_rd_wen       , // RD write enable
output wire [ REG_ADDR_R:0] s3_rd_addr      , // RD write addr
output wire [         XL:0] s3_rd_wdata     , // RD write data.

output wire                 csr_en          , // CSR Access Enable
output wire                 csr_wr          , // CSR Write Enable
output wire                 csr_wr_set      , // CSR Write - Set
output wire                 csr_wr_clr      , // CSR Write - Clear
output wire [         11:0] csr_addr        , // Address of the CSR to access.
output wire [         XL:0] csr_wdata       , // Data to be written to a CSR
input  wire [         XL:0] csr_rdata       , // CSR read data
input  wire                 csr_error       , // CSR access error

output wire                 trap_cpu        , // trap occured due to CPU
output wire                 trap_int        , // trap occured due to interrupt
output wire [ CF_CAUSE_R:0] trap_cause      , // 
output wire [         XL:0] trap_mtval      , // Value associated with trap.
output wire [         XL:0] trap_pc         , // PC associated with the trap.

output wire                 exec_mret       , // MRET instruction executed.
output wire                 instr_ret       ,

input  wire                 dmem_req        , // Memory request
input  wire [ MEM_ADDR_R:0] dmem_addr       , // Memory request address
input  wire                 dmem_wen        , // Memory request write enable
input  wire [ MEM_STRB_R:0] dmem_strb       , // Memory request write strobe
input  wire [ MEM_DATA_R:0] dmem_wdata      , // Memory write data.
input  wire                 dmem_gnt        , // Memory response valid
input  wire                 dmem_err        , // Memory response error
input  wire [ MEM_DATA_R:0] dmem_rdata      , // Memory response read data

`ifdef RVFI
input  wire [ REG_ADDR_R:0] s3_rs1_addr     ,
input  wire [ REG_ADDR_R:0] s3_rs2_addr     ,
input  wire [         XL:0] s3_rs1_rdata    ,
input  wire [         XL:0] s3_rs2_rdata    ,
`RVFI_OUTPUTS                               ,
`endif

output wire                 trs_valid       , // Instruction trace valid
output wire [         31:0] trs_instr       , // Instruction trace data
output wire [         XL:0] trs_pc            // Instruction trace PC

);


// Common parameters and width definitions.
`include "core_common.svh"

//
// MISC Useful signals
// ------------------------------------------------------------

// A new instruction will arrive on the next cycle.
wire   e_new_instr  =  s3_valid && s3_ready;

wire   e_instr_ret  =  e_new_instr && s3_full;

assign instr_ret    =  e_instr_ret;

wire   e_cf_change  = s3_cf_valid && s3_cf_ack;

assign s3_ready     = !s3_full  || s3_full && !cfu_wait;


//
// GPR Writeback control
// ------------------------------------------------------------

reg       rd_wen_enable;

always  @(posedge g_clk) begin
    if(!g_resetn) begin
        rd_wen_enable <= 1'b0;
    end else if(e_new_instr) begin
        rd_wen_enable <= 1'b1;
    end else if(s3_rd_wen) begin
        rd_wen_enable <= 1'b0;
    end
end

wire    wb_none    = s3_wb_op == WB_OP_NONE    ;
wire    wb_wdata   = s3_wb_op == WB_OP_WDATA   ;
wire    wb_lsu     = s3_wb_op == WB_OP_LSU     ;
wire    wb_csr     = s3_wb_op == WB_OP_CSR     ;

assign  s3_rd_wen  = rd_wen_enable && (wb_wdata || lsu_wen || wb_csr);

assign  s3_rd_wdata=
    {XLEN{wb_wdata  }}  & s3_wdata  |
    {XLEN{wb_lsu    }}  & lsu_rdata |
    {XLEN{wb_csr    }}  & csr_rdata ;

assign  s3_rd_addr = s3_rd          ;

//
// CSR Control
// ------------------------------------------------------------

reg     csr_op_done   ;

always @(posedge g_clk) begin
    if(!g_resetn) begin
        csr_op_done <= 1'b0;
    end else if(e_new_instr) begin
        csr_op_done <= 1'b0;
    end else if(csr_en) begin
        csr_op_done <= 1'b0;
    end
end

wire    csr_op_rd   = s3_csr_op[CSR_OP_RD ];
wire    csr_op_wr   = s3_csr_op[CSR_OP_WR ];
wire    csr_op_set  = s3_csr_op[CSR_OP_SET];
wire    csr_op_clr  = s3_csr_op[CSR_OP_CLR];

assign  csr_en      = !csr_op_done && (
        csr_op_rd || csr_op_wr || csr_op_set || csr_op_clr
    );

assign  csr_wr      = csr_op_wr     ;
assign  csr_wr_set  = csr_op_set    ;
assign  csr_wr_clr  = csr_op_clr    ;
assign  csr_addr    = s3_csr_addr   ;
assign  csr_wdata   = s3_wdata      ;


//
// LSU Control
// ------------------------------------------------------------

wire [ 5:0] data_shift     = {s3_wdata[2:0], 3'b000};

wire        lsu_wen        = lsu_load               ;

//
// Read data positioning.

wire [XL:0] lsu_rdata;

wire        lsu_load       = s3_lsu_op[LSU_OP_LOAD  ];
wire        lsu_store      = s3_lsu_op[LSU_OP_STORE ];
wire        lsu_byte       = s3_lsu_op[LSU_OP_BYTE  ];
wire        lsu_half       = s3_lsu_op[LSU_OP_HALF  ];
wire        lsu_word       = s3_lsu_op[LSU_OP_WORD  ];
wire        lsu_double     = s3_lsu_op[LSU_OP_DOUBLE];
wire        lsu_sext       = s3_lsu_op[LSU_OP_SEXT  ];

wire [XL:0] rdata_shifted  = dmem_rdata >> data_shift;

wire [XL:0] mask_ls_byte   = {56'h0,  8'hFF};
wire [XL:0] mask_ls_half   = {48'h0, 16'hFFFF};
wire [XL:0] mask_ls_word   = {32'h0, 32'hFFFFFFFF};

wire [XL:0] sext_byte      = {{56{lsu_sext && rdata_shifted[ 7]}},  8'b0};
wire [XL:0] sext_half      = {{48{lsu_sext && rdata_shifted[15]}}, 16'b0};
wire [XL:0] sext_word      = {{32{lsu_sext && rdata_shifted[31]}}, 32'b0};

wire [XL:0] rdata_byte     = (rdata_shifted & mask_ls_byte) | sext_byte;
wire [XL:0] rdata_half     = (rdata_shifted & mask_ls_half) | sext_half;
wire [XL:0] rdata_word     = (rdata_shifted & mask_ls_word) | sext_word;

assign      lsu_rdata      =
    lsu_byte    ? rdata_byte    :
    lsu_half    ? rdata_half    :
    lsu_word    ? rdata_word    :
                  dmem_rdata ;

//
// Control flow changes
// ------------------------------------------------------------

wire        cfu_wait  = 1'b0;

assign      s3_cf_target = 0;
assign      s3_cf_valid  = 0;

assign      exec_mret    = 1'b0;

//
// Traps
// ------------------------------------------------------------

// trap occured due to CPU
assign trap_cpu       = s3_trap;

assign trap_int       = 0 ; // trap occured due to interrupt

assign trap_cause     = s3_trap ? s3_rd_addr : 'b0 ;

assign trap_mtval     = 0 ;
assign trap_pc        = s3_pc ;

//
// Trace
// ------------------------------------------------------------

assign trs_valid = e_instr_ret  ;
assign trs_pc    = s3_pc        ;
assign trs_instr = s3_instr     ;


//
// RVFI Interface
// ------------------------------------------------------------

`ifdef RVFI

wire [ILEN   - 1 : 0] n_rvfi_intr         =  'b0;
wire                  n_rvfi_trap         = trap_cpu;

wire                  n_rvfi_mem_req_valid = dmem_req && dmem_gnt;
reg                   n_rvfi_mem_rsp_valid ;

always @(posedge g_clk) begin
    if(!g_resetn) n_rvfi_mem_rsp_valid <= 1'b0;
    else          n_rvfi_mem_rsp_valid <= n_rvfi_mem_req_valid;
end

wire [XLEN/8 - 1 : 0] n_rvfi_mem_rmask    = dmem_wen ? 8'b0 : dmem_strb;
wire [XLEN/8 - 1 : 0] n_rvfi_mem_wmask    = dmem_wen ? dmem_strb : 8'b0;

core_rvfi i_core_rvfi (
.g_clk              (g_clk                  ),
.g_resetn           (g_resetn               ),
`RVFI_CONN                                   ,
.n_valid            (e_instr_ret            ),
.n_insn             (s3_instr               ),
.n_intr             (rvfi_intr              ),
.n_trap             (n_rvfi_trap            ),
.n_rs1_addr         (s3_rs1_addr            ),
.n_rs2_addr         (s3_rs2_addr            ),
.n_rs1_rdata        (s3_rs1_rdata           ),
.n_rs2_rdata        (s3_rs2_rdata           ),
.n_rd_valid         (s3_rd_wen              ),
.n_rd_addr          (s3_rd_addr             ),
.n_rd_wdata         (s3_rd_wdata            ),
.n_cf_change        (e_cf_change            ),
.n_cf_target        (s3_cf_target           ),
.n_pc_rdata         (s3_pc                  ),
.n_pc_wdata         (s3_n_pc                ),
.n_mem_req_valid    (n_rvfi_mem_req_valid   ),
.n_mem_rsp_valid    (n_rvfi_mem_rsp_valid   ),
.n_mem_addr         (dmem_addr              ),
.n_mem_rmask        (n_rvfi_mem_rmask       ),
.n_mem_wmask        (n_rvfi_mem_wmask       ),
.n_mem_rdata        (lsu_rdata              ),
.n_mem_wdata        (dmem_wdata             )
);

`endif

endmodule
