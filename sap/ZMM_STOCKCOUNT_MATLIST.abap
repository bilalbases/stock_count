*&---------------------------------------------------------------------*
*& Report ZMM_STOCKCOUNT_MATLIST
*&---------------------------------------------------------------------*
*& Downloads the article list of one branch for the Stock Count app as
*& an Excel file (.xlsx) with columns:
*&   MATERIAL | BARCODE | UOM | BASE_UOM | FACTOR | DESCRIPTION
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
REPORT zmm_stockcount_matlist.

TABLES: mara.

TYPES: BEGIN OF ty_out,                      " string columns = text cells in Excel
         material    TYPE string,
         barcode     TYPE string,
         uom         TYPE string,
         base_uom    TYPE string,
         factor      TYPE string,
         description TYPE string,
       END OF ty_out,
       BEGIN OF ty_row,
         matnr TYPE mara-matnr,
         ean11 TYPE mean-ean11,
         meinh TYPE marm-meinh,
       END OF ty_row.

DATA: gt_out      TYPE STANDARD TABLE OF ty_out,
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
              p_file  TYPE string LOWER CASE DEFAULT 'C:\temp\material_list.xlsx',
              p_appl  RADIOBUTTON GROUP out,
              p_afile TYPE string LOWER CASE DEFAULT '/usr/sap/trans/stockcount/material_list.xlsx'.
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
        lv_base TYPE char3.
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
    APPEND ls_out TO gt_out.
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
      default_file_name = 'material_list.xlsx'
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
*& Needs ABAP 7.40 or newer (S/4HANA or ECC EhP7+).
*&---------------------------------------------------------------------*
