*&---------------------------------------------------------------------*
*& Report ZMM_STOCKCOUNT_MATLIST_PRICE
*&---------------------------------------------------------------------*
*& Copy of ZMM_STOCKCOUNT_MATLIST with two extra columns at the end:
*&   PRICE    = valuation price of ONE unit of the row's UOM, from the
*&              material master accounting view (MBEW) of the branch:
*&              moving average price (VERPR) when price control is V,
*&              standard price (STPRS) when it is S, divided by the
*&              price unit (PEINH) and multiplied by FACTOR.
*&              Example: 1 EA = 2.50, OTR of 10 EA -> EA row 2.50,
*&              OTR row 25.00. Empty when the article has no valuation.
*&   CURRENCY = company code currency of the branch (e.g. AED).
*& Promotions: if the barcode is in table ZPOS_EXCEL_CMPG with a value in
*& CUSTOMER_DISCOUNT, PRICE is the promotion price = price - discount
*& (never below 0). The table is read dynamically: its barcode field
*& (EAN11 / BARCODE / EAN ...), branch field (WERKS / PLANT / BRANCH) and
*& valid-from / valid-to date fields are found by name; only campaigns
*& of this branch valid today count. If one barcode has several, the one
*& with the latest valid-from date wins. Set GC_DISC_PCT = abap_true if
*& CUSTOMER_DISCOUNT is a percentage instead of an amount.
*& The file still loads in the Stock Count app (extra columns are
*& ignored there).
*&
*& Downloads the article list of one branch for the Stock Count app as
*& an Excel file (.xlsx) with columns:
*&   MATERIAL | BARCODE | UOM | BASE_UOM | FACTOR | DESCRIPTION |
*&   PRICE | CURRENCY
*& UOM is the unit of the barcode (e.g. OTR), BASE_UOM the article's base
*& unit (MARA-MEINS, e.g. EA) and FACTOR how many base units one UOM holds
*& (MARM-UMREZ / UMREN, e.g. 10). The app converts counts to the base unit.
*& All columns are stored as text, so barcodes keep every digit
*& (no 1E+12 format). One row per barcode: an article with an EA and a
*& CAR barcode gives two rows. Upload the file in the app with
*& "Upload materials".
*&
*& Selection: Branch (plant) is mandatory. Material is optional; leave it
*& empty to download all articles of the branch.
*&
*& Skipped automatically:
*&   - articles with a deletion flag (client or plant level)
*&   - inactive articles: cross-plant status (MARA-MSTAE) or plant status
*&     (MARC-MMSTA) is set. To treat only some status codes as inactive,
*&     fill GR_INACTIVE in INITIALIZATION below.
*&
*& Output: ALV list (default; in background it goes to the spool),
*&         PC file (dialog only), or application server file (AL11).
*& With "Save to PC" in a background job, the file is written to the
*& application server instead.
*&---------------------------------------------------------------------*
REPORT zmm_stockcount_matlist_price.

TABLES: mara.

TYPES: BEGIN OF ty_out,                      " string columns = text cells in Excel
         material    TYPE string,
         barcode     TYPE string,
         uom         TYPE string,
         base_uom    TYPE string,
         factor      TYPE string,
         description TYPE string,
         price       TYPE string,
         currency    TYPE string,
       END OF ty_out,
       BEGIN OF ty_row,
         matnr TYPE mara-matnr,
         ean11 TYPE mean-ean11,
         meinh TYPE marm-meinh,
       END OF ty_row.

TYPES: BEGIN OF ty_disc,
         barcode TYPE string,            " without leading zeros
         disc    TYPE p LENGTH 16 DECIMALS 4,
         datab   TYPE d,
       END OF ty_disc.

CONSTANTS: gc_disc_tab TYPE tabname   VALUE 'ZPOS_EXCEL_CMPG',
           gc_disc_fld TYPE fieldname VALUE 'CUSTOMER_DISCOUNT',
           gc_disc_pct TYPE abap_bool VALUE abap_false.  " abap_true = discount is a %

DATA: gt_disc     TYPE HASHED TABLE OF ty_disc WITH UNIQUE KEY barcode,
      gt_out      TYPE STANDARD TABLE OF ty_out,
      gv_xlsx     TYPE xstring,
      gr_inactive TYPE RANGE OF mara-mstae.   " empty = any status counts as inactive

*--- Selection screen --------------------------------------------------
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
  PARAMETERS:     p_werks TYPE marc-werks OBLIGATORY.  " Branch
  SELECT-OPTIONS: s_matnr FOR mara-matnr.              " Optional, empty = all
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002.
  PARAMETERS: p_alv   RADIOBUTTON GROUP out DEFAULT 'X',
              p_pc    RADIOBUTTON GROUP out,
              p_file  TYPE string LOWER CASE DEFAULT 'C:\temp\material_list_price.xlsx',
              p_appl  RADIOBUTTON GROUP out,
              p_afile TYPE string LOWER CASE DEFAULT '/usr/sap/trans/stockcount/material_list_price.xlsx'.
SELECTION-SCREEN END OF BLOCK b2.

INITIALIZATION.
  " Example: only status codes 01 and 02 mean inactive
  " APPEND VALUE #( sign = 'I' option = 'EQ' low = '01' ) TO gr_inactive.
  " APPEND VALUE #( sign = 'I' option = 'EQ' low = '02' ) TO gr_inactive.

AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_file.
  PERFORM f4_file.

*--- Main --------------------------------------------------------------
START-OF-SELECTION.
  PERFORM select_data.
  IF gt_out IS INITIAL.
    MESSAGE |No active articles with barcodes found for branch { p_werks }| TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.
  " ALV: shown on screen in dialog; in a background job it goes to the spool.
  IF p_alv = abap_true.
    PERFORM show_alv.
    RETURN.
  ENDIF.

  PERFORM build_xlsx.
  IF gv_xlsx IS INITIAL.
    RETURN.
  ENDIF.

  " Background jobs cannot write to the PC: use the application server there.
  IF sy-batch = abap_true OR p_appl = abap_true.
    PERFORM write_appl_server.
  ELSE.
    PERFORM download_pc.
  ENDIF.

*&---------------------------------------------------------------------*
FORM select_data.
  TYPES: BEGIN OF ty_mat,
           matnr TYPE mara-matnr,
           meins TYPE mara-meins,
           mstae TYPE mara-mstae,
           mmsta TYPE marc-mmsta,
         END OF ty_mat,
         BEGIN OF ty_val,
           matnr TYPE mbew-matnr,
           vprsv TYPE mbew-vprsv,
           verpr TYPE mbew-verpr,
           stprs TYPE mbew-stprs,
           peinh TYPE mbew-peinh,
         END OF ty_val,
         BEGIN OF ty_conv,
           matnr TYPE marm-matnr,
           meinh TYPE marm-meinh,
           umrez TYPE marm-umrez,
           umren TYPE marm-umren,
         END OF ty_conv.
  DATA: lt_mat  TYPE STANDARD TABLE OF ty_mat,
        lt_bc   TYPE STANDARD TABLE OF ty_row,
        lt_marm TYPE STANDARD TABLE OF ty_row,
        lt_makt TYPE HASHED TABLE OF makt WITH UNIQUE KEY matnr spras,
        ls_makt TYPE makt,
        ls_out  TYPE ty_out,
        lt_conv TYPE SORTED TABLE OF ty_conv WITH UNIQUE KEY matnr meinh,
        ls_conv TYPE ty_conv,
        lt_matk TYPE SORTED TABLE OF ty_mat WITH NON-UNIQUE KEY matnr,
        ls_mat  TYPE ty_mat,
        lv_fact TYPE p LENGTH 15 DECIMALS 6,
        lv_fstr TYPE string,
        lv_mat  TYPE char40,
        lv_uom  TYPE char3,
        lv_base TYPE char3,
        lt_val  TYPE SORTED TABLE OF ty_val WITH UNIQUE KEY matnr,
        ls_val  TYPE ty_val,
        lv_bwkey TYPE t001w-bwkey,
        lv_waers TYPE t001-waers,
        lv_price TYPE p LENGTH 16 DECIMALS 4,
        lv_pstr  TYPE string,
        lv_bckey TYPE string,
        ls_disc  TYPE ty_disc.
  FIELD-SYMBOLS: <m> TYPE ty_mat,
                 <r> TYPE ty_row.

  " 1. Articles of the branch, without deletion flags
  SELECT a~matnr a~meins a~mstae c~mmsta
    FROM mara AS a
    INNER JOIN marc AS c ON c~matnr = a~matnr
    INTO CORRESPONDING FIELDS OF TABLE lt_mat
    WHERE c~werks = p_werks
      AND a~matnr IN s_matnr
      AND a~lvorm = space
      AND c~lvorm = space.

  " 2. Drop inactive articles (status set)
  LOOP AT lt_mat ASSIGNING <m>.
    IF ( <m>-mstae IS NOT INITIAL AND ( gr_inactive IS INITIAL OR <m>-mstae IN gr_inactive ) )
    OR ( <m>-mmsta IS NOT INITIAL AND ( gr_inactive IS INITIAL OR <m>-mmsta IN gr_inactive ) ).
      DELETE lt_mat.
    ENDIF.
  ENDLOOP.
  IF lt_mat IS INITIAL.
    RETURN.
  ENDIF.

  " 3. All barcodes per unit (MEAN) plus the main barcode per unit (MARM)
  SELECT matnr ean11 meinh FROM mean
    INTO CORRESPONDING FIELDS OF TABLE lt_bc
    FOR ALL ENTRIES IN lt_mat
    WHERE matnr = lt_mat-matnr
      AND ean11 <> space.

  SELECT matnr ean11 meinh FROM marm
    INTO CORRESPONDING FIELDS OF TABLE lt_marm
    FOR ALL ENTRIES IN lt_mat
    WHERE matnr = lt_mat-matnr
      AND ean11 <> space.

  APPEND LINES OF lt_marm TO lt_bc.
  SORT lt_bc BY ean11 matnr meinh.
  DELETE ADJACENT DUPLICATES FROM lt_bc COMPARING ean11.   " one row per barcode
  SORT lt_bc BY matnr meinh ean11.

  " 3b. Unit conversions: 1 <meinh> = umrez / umren base units
  SELECT matnr meinh umrez umren FROM marm
    INTO CORRESPONDING FIELDS OF TABLE lt_conv
    FOR ALL ENTRIES IN lt_mat
    WHERE matnr = lt_mat-matnr.
  lt_matk = lt_mat.

  " 3c. Prices: valuation area of the branch, its currency, and the
  "     valuation price per article (MBEW, no valuation type split)
  SELECT SINGLE bwkey FROM t001w INTO lv_bwkey WHERE werks = p_werks.
  SELECT SINGLE t~waers FROM t001k AS k
    INNER JOIN t001 AS t ON t~bukrs = k~bukrs
    INTO lv_waers
    WHERE k~bwkey = lv_bwkey.
  SELECT matnr vprsv verpr stprs peinh FROM mbew
    INTO CORRESPONDING FIELDS OF TABLE lt_val
    FOR ALL ENTRIES IN lt_mat
    WHERE matnr = lt_mat-matnr
      AND bwkey = lv_bwkey
      AND bwtar = space.

  " 3d. Promotion discounts per barcode (ZPOS_EXCEL_CMPG)
  PERFORM read_discounts.

  " 4. Descriptions
  SELECT * FROM makt
    INTO TABLE lt_makt
    FOR ALL ENTRIES IN lt_mat
    WHERE matnr = lt_mat-matnr
      AND spras = sy-langu.

  " 5. Output rows in external format (material without leading zeros, unit as users see it)
  LOOP AT lt_bc ASSIGNING <r>.
    CLEAR ls_out.
    CALL FUNCTION 'CONVERSION_EXIT_MATN1_OUTPUT'
      EXPORTING input  = <r>-matnr
      IMPORTING output = lv_mat.
    CALL FUNCTION 'CONVERSION_EXIT_CUNIT_OUTPUT'
      EXPORTING  input          = <r>-meinh
                 language       = sy-langu
      IMPORTING  output         = lv_uom
      EXCEPTIONS unit_not_found = 1
                 OTHERS         = 2.
    IF sy-subrc <> 0.
      lv_uom = <r>-meinh.
    ENDIF.
    ls_out-material = condense( val = lv_mat ).
    ls_out-barcode  = condense( val = <r>-ean11 ).
    ls_out-uom      = condense( val = lv_uom ).

    " Base unit and conversion factor
    CLEAR: ls_mat, ls_conv, lv_base.
    READ TABLE lt_matk INTO ls_mat WITH KEY matnr = <r>-matnr.
    CALL FUNCTION 'CONVERSION_EXIT_CUNIT_OUTPUT'
      EXPORTING  input          = ls_mat-meins
                 language       = sy-langu
      IMPORTING  output         = lv_base
      EXCEPTIONS unit_not_found = 1
                 OTHERS         = 2.
    IF sy-subrc <> 0.
      lv_base = ls_mat-meins.
    ENDIF.
    ls_out-base_uom = condense( val = lv_base ).
    READ TABLE lt_conv INTO ls_conv WITH TABLE KEY matnr = <r>-matnr meinh = <r>-meinh.
    IF sy-subrc = 0 AND ls_conv-umren <> 0.
      lv_fact = ls_conv-umrez / ls_conv-umren.
    ELSE.
      lv_fact = 1.
    ENDIF.
    lv_fstr = |{ lv_fact DECIMALS = 6 }|.
    IF lv_fstr CS '.'.          " 10.000000 -> 10, 0.500000 -> 0.5
      lv_fstr = replace( val = lv_fstr regex = '\.?0+$' with = '' ).
    ENDIF.
    ls_out-factor = condense( val = lv_fstr ).
    READ TABLE lt_makt INTO ls_makt WITH TABLE KEY matnr = <r>-matnr spras = sy-langu.
    IF sy-subrc = 0.
      ls_out-description = ls_makt-maktx.
    ENDIF.

    " Price of one row UOM = price per base unit x factor
    CLEAR ls_val.
    READ TABLE lt_val INTO ls_val WITH TABLE KEY matnr = <r>-matnr.
    IF sy-subrc = 0.
      IF ls_val-peinh = 0.
        ls_val-peinh = 1.
      ENDIF.
      IF ls_val-vprsv = 'S'.
        lv_price = ls_val-stprs * lv_fact / ls_val-peinh.
      ELSE.
        lv_price = ls_val-verpr * lv_fact / ls_val-peinh.
      ENDIF.
      " Promotion: barcode found with a customer discount -> promotion price
      lv_bckey = condense( val = <r>-ean11 ).
      SHIFT lv_bckey LEFT DELETING LEADING '0'.
      READ TABLE gt_disc INTO ls_disc WITH TABLE KEY barcode = lv_bckey.
      IF sy-subrc = 0.
        IF gc_disc_pct = abap_true.
          lv_price = lv_price * ( 100 - ls_disc-disc ) / 100.
        ELSE.
          lv_price = lv_price - ls_disc-disc.
        ENDIF.
        IF lv_price < 0.
          lv_price = 0.
        ENDIF.
      ENDIF.
      lv_pstr = |{ lv_price DECIMALS = 4 }|.     " 25.5000 -> 25.50, 0.1250 -> 0.125
      lv_pstr = replace( val = lv_pstr regex = '(\.\d\d\d?)0+$' with = '$1' ).
      lv_pstr = replace( val = lv_pstr regex = '(\.\d\d)0$' with = '$1' ).
      ls_out-price    = condense( val = lv_pstr ).
      ls_out-currency = lv_waers.
    ENDIF.
    APPEND ls_out TO gt_out.
  ENDLOOP.
ENDFORM.

*&---------------------------------------------------------------------*
*& Reads ZPOS_EXCEL_CMPG into GT_DISC (barcode -> discount). Field names
*& other than CUSTOMER_DISCOUNT are looked up, so the exact table layout
*& does not have to be known here.
FORM read_discounts.
  DATA: lo_type  TYPE REF TO cl_abap_typedescr,
        lo_struc TYPE REF TO cl_abap_structdescr,
        lt_flds  TYPE ddfields,
        ls_fld   TYPE dfies,
        lr_tab   TYPE REF TO data,
        lv_bc_f  TYPE fieldname,
        lv_pl_f  TYPE fieldname,
        lv_fr_f  TYPE fieldname,
        lv_to_f  TYPE fieldname,
        lv_has_d TYPE abap_bool,
        lv_where TYPE string,
        lv_str   TYPE string,
        lv_date  TYPE d,
        ls_disc  TYPE ty_disc,
        ls_old   TYPE ty_disc,
        lx_err   TYPE REF TO cx_root.
  FIELD-SYMBOLS: <t> TYPE STANDARD TABLE,
                 <w> TYPE any,
                 <f> TYPE any.

  cl_abap_typedescr=>describe_by_name(
    EXPORTING  p_name         = gc_disc_tab
    RECEIVING  p_descr_ref    = lo_type
    EXCEPTIONS type_not_found = 1
               OTHERS         = 2 ).
  IF sy-subrc <> 0.
    MESSAGE |Table { gc_disc_tab } not found - prices without promotions| TYPE 'S' DISPLAY LIKE 'W'.
    RETURN.
  ENDIF.
  lo_struc ?= lo_type.
  lt_flds = lo_struc->get_ddic_field_list( ).

  LOOP AT lt_flds INTO ls_fld.
    CASE ls_fld-fieldname.
      WHEN gc_disc_fld.
        lv_has_d = abap_true.
      WHEN 'EAN11' OR 'BARCODE' OR 'EAN' OR 'ZBARCODE' OR 'ZEAN' OR 'EAN_CODE' OR 'GTIN' OR 'UPC'.
        IF lv_bc_f IS INITIAL. lv_bc_f = ls_fld-fieldname. ENDIF.
      WHEN 'WERKS' OR 'PLANT' OR 'BRANCH' OR 'SITE' OR 'STORE' OR 'ZWERKS'.
        IF lv_pl_f IS INITIAL. lv_pl_f = ls_fld-fieldname. ENDIF.
      WHEN 'DATAB' OR 'VALID_FROM' OR 'FROM_DATE' OR 'DATE_FROM' OR 'START_DATE' OR 'BEGDA' OR 'VALIDFROM'.
        IF ls_fld-inttype = 'D' AND lv_fr_f IS INITIAL. lv_fr_f = ls_fld-fieldname. ENDIF.
      WHEN 'DATBI' OR 'VALID_TO' OR 'TO_DATE' OR 'DATE_TO' OR 'END_DATE' OR 'ENDDA' OR 'VALIDTO'.
        IF ls_fld-inttype = 'D' AND lv_to_f IS INITIAL. lv_to_f = ls_fld-fieldname. ENDIF.
    ENDCASE.
  ENDLOOP.
  IF lv_bc_f IS INITIAL.                      " any other field with BARCODE / EAN in its name
    LOOP AT lt_flds INTO ls_fld WHERE fieldname CS 'BARCODE' OR fieldname CS 'EAN'.
      lv_bc_f = ls_fld-fieldname.
      EXIT.
    ENDLOOP.
  ENDIF.
  IF lv_has_d = abap_false OR lv_bc_f IS INITIAL.
    MESSAGE |{ gc_disc_tab }: barcode or { gc_disc_fld } field not found - prices without promotions|
      TYPE 'S' DISPLAY LIKE 'W'.
    RETURN.
  ENDIF.

  IF lv_pl_f IS NOT INITIAL.
    lv_where = |{ lv_pl_f } = '{ p_werks }'|.
  ENDIF.

  CREATE DATA lr_tab TYPE STANDARD TABLE OF (gc_disc_tab).
  ASSIGN lr_tab->* TO <t>.
  TRY.
      SELECT * FROM (gc_disc_tab) INTO TABLE <t> WHERE (lv_where).
    CATCH cx_root INTO lx_err.
      MESSAGE |{ gc_disc_tab }: { lx_err->get_text( ) }| TYPE 'S' DISPLAY LIKE 'W'.
      RETURN.
  ENDTRY.

  LOOP AT <t> ASSIGNING <w>.
    CLEAR ls_disc.
    " Only campaigns valid today
    IF lv_fr_f IS NOT INITIAL.
      ASSIGN COMPONENT lv_fr_f OF STRUCTURE <w> TO <f>.
      lv_date = <f>.
      IF lv_date IS NOT INITIAL AND lv_date > sy-datum.
        CONTINUE.
      ENDIF.
      ls_disc-datab = lv_date.
    ENDIF.
    IF lv_to_f IS NOT INITIAL.
      ASSIGN COMPONENT lv_to_f OF STRUCTURE <w> TO <f>.
      lv_date = <f>.
      IF lv_date IS NOT INITIAL AND lv_date < sy-datum.
        CONTINUE.
      ENDIF.
    ENDIF.

    " Discount value (works for number and text fields, e.g. '5.00' or '5%')
    ASSIGN COMPONENT gc_disc_fld OF STRUCTURE <w> TO <f>.
    lv_str = |{ <f> }|.
    REPLACE ALL OCCURRENCES OF '%' IN lv_str WITH ''.
    REPLACE ALL OCCURRENCES OF ',' IN lv_str WITH '.'.
    CONDENSE lv_str NO-GAPS.
    IF lv_str IS INITIAL.
      CONTINUE.
    ENDIF.
    TRY.
        ls_disc-disc = lv_str.
      CATCH cx_root.
        CONTINUE.
    ENDTRY.
    IF ls_disc-disc <= 0.
      CONTINUE.
    ENDIF.

    ASSIGN COMPONENT lv_bc_f OF STRUCTURE <w> TO <f>.
    ls_disc-barcode = condense( val = |{ <f> }| ).
    SHIFT ls_disc-barcode LEFT DELETING LEADING '0'.
    IF ls_disc-barcode IS INITIAL.
      CONTINUE.
    ENDIF.

    READ TABLE gt_disc INTO ls_old WITH TABLE KEY barcode = ls_disc-barcode.
    IF sy-subrc <> 0.
      INSERT ls_disc INTO TABLE gt_disc.
    ELSEIF ls_disc-datab >= ls_old-datab.     " newest campaign wins
      MODIFY TABLE gt_disc FROM ls_disc.
    ENDIF.
  ENDLOOP.
ENDFORM.

*&---------------------------------------------------------------------*
*& ALV list. Use the toolbar "Export > Spreadsheet" to save as Excel;
*& the columns are text, so barcodes keep all digits.
FORM show_alv.
  DATA: lo_salv TYPE REF TO cl_salv_table,
        lo_cols TYPE REF TO cl_salv_columns_table,
        lx_err  TYPE REF TO cx_root.

  TRY.
      cl_salv_table=>factory( IMPORTING r_salv_table = lo_salv
                              CHANGING  t_table      = gt_out ).
      lo_salv->get_functions( )->set_all( abap_true ).
      lo_salv->get_display_settings( )->set_list_header(
        |Stock Count material list - branch { p_werks } - { lines( gt_out ) } barcodes| ).
      lo_salv->get_display_settings( )->set_striped_pattern( abap_true ).
      lo_cols = lo_salv->get_columns( ).
      lo_cols->set_optimize( abap_true ).
      PERFORM set_header USING lo_cols 'MATERIAL'.
      PERFORM set_header USING lo_cols 'BARCODE'.
      PERFORM set_header USING lo_cols 'UOM'.
      PERFORM set_header USING lo_cols 'BASE_UOM'.
      PERFORM set_header USING lo_cols 'FACTOR'.
      PERFORM set_header USING lo_cols 'DESCRIPTION'.
      PERFORM set_header USING lo_cols 'PRICE'.
      PERFORM set_header USING lo_cols 'CURRENCY'.
      lo_salv->display( ).
    CATCH cx_root INTO lx_err.
      MESSAGE lx_err->get_text( ) TYPE 'S' DISPLAY LIKE 'E'.
  ENDTRY.
ENDFORM.

*&---------------------------------------------------------------------*
*& Build the .xlsx in memory with SALV (works in dialog and background)
FORM build_xlsx.
  DATA: lo_salv TYPE REF TO cl_salv_table,
        lo_cols TYPE REF TO cl_salv_columns_table,
        lx_err  TYPE REF TO cx_root.

  TRY.
      cl_salv_table=>factory( IMPORTING r_salv_table = lo_salv
                              CHANGING  t_table      = gt_out ).
      lo_cols = lo_salv->get_columns( ).
      PERFORM set_header USING lo_cols 'MATERIAL'.
      PERFORM set_header USING lo_cols 'BARCODE'.
      PERFORM set_header USING lo_cols 'UOM'.
      PERFORM set_header USING lo_cols 'BASE_UOM'.
      PERFORM set_header USING lo_cols 'FACTOR'.
      PERFORM set_header USING lo_cols 'DESCRIPTION'.
      PERFORM set_header USING lo_cols 'PRICE'.
      PERFORM set_header USING lo_cols 'CURRENCY'.
      gv_xlsx = lo_salv->to_xml( xml_type = if_salv_bs_xml=>c_type_xlsx ).
    CATCH cx_root INTO lx_err.
      MESSAGE |Could not create the Excel file: { lx_err->get_text( ) }| TYPE 'S' DISPLAY LIKE 'E'.
  ENDTRY.
ENDFORM.

FORM set_header USING io_cols TYPE REF TO cl_salv_columns_table iv_name TYPE lvc_fname.
  DATA lo_col TYPE REF TO cl_salv_column.
  lo_col = io_cols->get_column( iv_name ).
  lo_col->set_short_text( CONV #( iv_name ) ).
  lo_col->set_medium_text( CONV #( iv_name ) ).
  lo_col->set_long_text( CONV #( iv_name ) ).
ENDFORM.

*&---------------------------------------------------------------------*
FORM download_pc.
  DATA: lt_bin TYPE solix_tab,
        lv_len TYPE i.
  lv_len = xstrlen( gv_xlsx ).
  lt_bin = cl_bcs_convert=>xstring_to_solix( gv_xlsx ).

  cl_gui_frontend_services=>gui_download(
    EXPORTING
      filename     = p_file
      filetype     = 'BIN'
      bin_filesize = lv_len
    CHANGING
      data_tab     = lt_bin
    EXCEPTIONS
      OTHERS       = 1 ).
  IF sy-subrc = 0.
    MESSAGE |{ lines( gt_out ) } barcodes downloaded to { p_file }| TYPE 'S'.
  ELSE.
    MESSAGE |Download to { p_file } failed| TYPE 'S' DISPLAY LIKE 'E'.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
FORM write_appl_server.
  DATA lv_msg TYPE string.

  OPEN DATASET p_afile FOR OUTPUT IN BINARY MODE MESSAGE lv_msg.
  IF sy-subrc <> 0.
    MESSAGE |Cannot open { p_afile }: { lv_msg }| TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.
  TRANSFER gv_xlsx TO p_afile.
  CLOSE DATASET p_afile.

  " Shows in the job log (SM37) and on screen
  MESSAGE |{ lines( gt_out ) } barcodes written to { p_afile }| TYPE 'S'.
ENDFORM.

*&---------------------------------------------------------------------*
FORM f4_file.
  DATA: lv_file   TYPE string,
        lv_path   TYPE string,
        lv_full   TYPE string,
        lv_action TYPE i.
  cl_gui_frontend_services=>file_save_dialog(
    EXPORTING
      default_extension = 'xlsx'
      default_file_name = 'material_list_price.xlsx'
      file_filter       = 'Excel files (*.xlsx)|*.xlsx'
    CHANGING
      filename          = lv_file
      path              = lv_path
      fullpath          = lv_full
      user_action       = lv_action
    EXCEPTIONS
      OTHERS            = 1 ).
  IF sy-subrc = 0 AND lv_action = cl_gui_frontend_services=>action_ok.
    p_file = lv_full.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Text elements to create in SE38 > Goto > Text elements:
*&   Text symbols:    001 = Selection,  002 = Output
*&   Selection texts: P_WERKS = Branch (plant), S_MATNR = Material,
*&                    P_ALV = Show list (ALV),
*&                    P_PC = Save to PC,  P_FILE = PC file,
*&                    P_APPL = Save to app. server,
*&                    P_AFILE = App. server file (AL11)
*&
*& Background job: SM36, step = this report with a variant for the
*& branch. It writes to P_AFILE; make sure that folder exists (AL11).
*& Authorization note: PRICE shows valuation prices; restrict the new
*& transaction (SE93) to users allowed to see them.
*& Needs ABAP 7.40 or newer (S/4HANA or ECC EhP7+).
*&---------------------------------------------------------------------*
