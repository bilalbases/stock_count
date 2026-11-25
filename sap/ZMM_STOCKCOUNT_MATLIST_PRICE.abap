*&---------------------------------------------------------------------*
*& Report ZMM_STOCKCOUNT_MATLIST_PRICE
*&---------------------------------------------------------------------*
*& Copy of ZMM_STOCKCOUNT_MATLIST with two extra columns at the end:
*&   PRICE    = selling price of ONE unit of the row's UOM, from the
*&              VKP0 condition records (as in VK13) valid today: first
*&              the branch (site) level record, else the sales org /
*&              distribution channel level record. The sales org and
*&              channel come from the branch (T001W) unless entered on
*&              the selection screen. If there is a record for the
*&              row's own unit it is used as is, otherwise the price is
*&              converted with the unit factors (EA 2.50 -> OTR of 10
*&              EA 25.00). Empty when the article has no VKP0 price.
*&   CURRENCY = currency of the condition record (e.g. AED).
*& The condition tables read are listed in GT_VKP0_TABS (INITIALIZATION):
*& A071 (site level) and A004 (sales org / channel level) by default.
*& If your VKP0 access sequence uses other tables (see VK13 > key
*& combination, or V/07), add or change them there.
*& Promotions: if table ZPOS_EXCEL_CMPG has the row's material AND unit
*& (MATNR + UOM = this barcode) for this branch (STORE_CODE = branch)
*& with a CUSTOMER_DISCOUNT, and today is between VALIDITY_FROM and
*& VALIDITY_TO, PRICE is the promotion price = price - discount
*& (never below 0). Other units of the same article keep normal price.
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
       END OF ty_row,
       BEGIN OF ty_sp,                       " selling price per condition unit
         matnr TYPE mara-matnr,
         kmein TYPE konp-kmein,
         kbetr TYPE konp-kbetr,
         kpein TYPE konp-kpein,
         konwa TYPE konp-konwa,
       END OF ty_sp,
       tt_sp TYPE SORTED TABLE OF ty_sp WITH UNIQUE KEY matnr kmein.

TYPES: BEGIN OF ty_disc,
         matnr TYPE mara-matnr,
         uom   TYPE mara-meins,
         disc  TYPE netwr,
       END OF ty_disc.

DATA: gt_vkp0_tabs TYPE STANDARD TABLE OF tabname WITH DEFAULT KEY,  " in priority order
      gt_disc     TYPE HASHED TABLE OF ty_disc WITH UNIQUE KEY matnr uom,
      gt_out      TYPE STANDARD TABLE OF ty_out,
      gv_xlsx     TYPE xstring,
      gr_inactive TYPE RANGE OF mara-mstae.   " empty = any status counts as inactive

*--- Selection screen --------------------------------------------------
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
  PARAMETERS:     p_werks TYPE marc-werks OBLIGATORY.  " Branch
  SELECT-OPTIONS: s_matnr FOR mara-matnr.              " Optional, empty = all
  PARAMETERS:     p_vkorg TYPE t001w-vkorg,            " Optional, empty = from branch
                  p_vtweg TYPE t001w-vtweg.            " Optional, empty = from branch
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002.
  PARAMETERS: p_alv   RADIOBUTTON GROUP out DEFAULT 'X',
              p_pc    RADIOBUTTON GROUP out,
              p_file  TYPE string LOWER CASE DEFAULT 'C:\temp\material_list_price.xlsx',
              p_appl  RADIOBUTTON GROUP out,
              p_afile TYPE string LOWER CASE DEFAULT '/usr/sap/trans/stockcount/material_list_price.xlsx'.
SELECTION-SCREEN END OF BLOCK b2.

INITIALIZATION.
  " VKP0 condition tables, most specific first
  APPEND 'A071' TO gt_vkp0_tabs.     " Sales org / Distr. channel / Site / Material
  APPEND 'A004' TO gt_vkp0_tabs.     " Sales org / Distr. channel / Material
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
        lv_base TYPE char3,
        lt_sp   TYPE tt_sp,
        ls_sp   TYPE ty_sp,
        lv_cfac TYPE p LENGTH 15 DECIMALS 6,
        lv_found TYPE abap_bool,
        lv_price TYPE p LENGTH 16 DECIMALS 4,
        lv_pstr  TYPE string,
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

  " 3c. Selling prices (VKP0 condition records valid today)
  PERFORM read_vkp0 CHANGING lt_sp.

  " 3d. Promotion discounts per article + unit (ZPOS_EXCEL_CMPG)
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

    " Selling price of one row UOM: record for this unit, else convert
    "   from the record of another unit via the unit factors
    lv_found = abap_false.
    READ TABLE lt_sp INTO ls_sp WITH TABLE KEY matnr = <r>-matnr kmein = <r>-meinh.
    IF sy-subrc = 0.
      lv_found = abap_true.
      IF ls_sp-kpein = 0. ls_sp-kpein = 1. ENDIF.
      lv_price = ls_sp-kbetr / ls_sp-kpein.
    ELSE.
      LOOP AT lt_sp INTO ls_sp WHERE matnr = <r>-matnr.
        CLEAR ls_conv.
        READ TABLE lt_conv INTO ls_conv WITH TABLE KEY matnr = <r>-matnr meinh = ls_sp-kmein.
        IF sy-subrc = 0 AND ls_conv-umrez <> 0 AND ls_conv-umren <> 0.
          lv_cfac = ls_conv-umrez / ls_conv-umren.        " base units per condition unit
        ELSEIF ls_sp-kmein = ls_mat-meins.
          lv_cfac = 1.
        ELSE.
          CONTINUE.
        ENDIF.
        IF ls_sp-kpein = 0. ls_sp-kpein = 1. ENDIF.
        lv_price = ls_sp-kbetr / ls_sp-kpein / lv_cfac * lv_fact.
        lv_found = abap_true.
        EXIT.
      ENDLOOP.
    ENDIF.
    IF lv_found = abap_true.
      " Promotion: barcode found with a customer discount -> promotion price
      READ TABLE gt_disc INTO ls_disc WITH TABLE KEY matnr = <r>-matnr uom = <r>-meinh.
      IF sy-subrc = 0.
        lv_price = lv_price - ls_disc-disc.
        IF lv_price < 0.
          lv_price = 0.
        ENDIF.
      ENDIF.
      lv_pstr = |{ lv_price DECIMALS = 4 }|.     " 25.5000 -> 25.50, 0.1250 -> 0.125
      lv_pstr = replace( val = lv_pstr regex = '(\.\d\d\d?)0+$' with = '$1' ).
      lv_pstr = replace( val = lv_pstr regex = '(\.\d\d)0$' with = '$1' ).
      ls_out-price    = condense( val = lv_pstr ).
      ls_out-currency = ls_sp-konwa.
    ENDIF.
    APPEND ls_out TO gt_out.
  ENDLOOP.
ENDFORM.

*&---------------------------------------------------------------------*
*& Reads today's VKP0 selling prices of the branch into CT_SP
*& (material + condition unit). Tables in GT_VKP0_TABS are read in
*& order; the first one that has a price for an article/unit wins.
*& Fields WERKS and VRKME are only used when the table has them.
FORM read_vkp0 CHANGING ct_sp TYPE tt_sp.
  TYPES: BEGIN OF ty_key,
           knumh TYPE konh-knumh,
           matnr TYPE mara-matnr,
         END OF ty_key.
  DATA: lv_vkorg TYPE t001w-vkorg,
        lv_vtweg TYPE t001w-vtweg,
        lv_tab   TYPE tabname,
        lv_where TYPE string,
        lo_type  TYPE REF TO cl_abap_typedescr,
        lo_struc TYPE REF TO cl_abap_structdescr,
        lt_flds  TYPE ddfields,
        lr_tab   TYPE REF TO data,
        lt_key   TYPE STANDARD TABLE OF ty_key,
        ls_key   TYPE ty_key,
        lt_konp  TYPE SORTED TABLE OF konp WITH NON-UNIQUE KEY knumh,
        ls_konp  TYPE konp,
        ls_sp    TYPE ty_sp,
        lx_err   TYPE REF TO cx_root.
  FIELD-SYMBOLS: <t> TYPE STANDARD TABLE,
                 <w> TYPE any,
                 <f> TYPE any.

  SELECT SINGLE vkorg vtweg FROM t001w INTO (lv_vkorg, lv_vtweg) WHERE werks = p_werks.
  IF p_vkorg IS NOT INITIAL. lv_vkorg = p_vkorg. ENDIF.
  IF p_vtweg IS NOT INITIAL. lv_vtweg = p_vtweg. ENDIF.
  IF lv_vkorg IS INITIAL OR lv_vtweg IS INITIAL.
    MESSAGE |Branch { p_werks } has no sales org / distribution channel - enter them on the selection screen|
      TYPE 'S' DISPLAY LIKE 'W'.
  ENDIF.

  LOOP AT gt_vkp0_tabs INTO lv_tab.
    cl_abap_typedescr=>describe_by_name(
      EXPORTING  p_name         = lv_tab
      RECEIVING  p_descr_ref    = lo_type
      EXCEPTIONS type_not_found = 1
                 OTHERS         = 2 ).
    CHECK sy-subrc = 0.
    lo_struc ?= lo_type.
    lt_flds = lo_struc->get_ddic_field_list( ).

    lv_where = |KAPPL = 'V' AND KSCHL = 'VKP0' AND DATAB <= '{ sy-datum }' AND DATBI >= '{ sy-datum }'|.
    READ TABLE lt_flds TRANSPORTING NO FIELDS WITH KEY fieldname = 'VKORG'.
    IF sy-subrc = 0. lv_where = |{ lv_where } AND VKORG = '{ lv_vkorg }'|. ENDIF.
    READ TABLE lt_flds TRANSPORTING NO FIELDS WITH KEY fieldname = 'VTWEG'.
    IF sy-subrc = 0. lv_where = |{ lv_where } AND VTWEG = '{ lv_vtweg }'|. ENDIF.
    READ TABLE lt_flds TRANSPORTING NO FIELDS WITH KEY fieldname = 'WERKS'.
    IF sy-subrc = 0. lv_where = |{ lv_where } AND WERKS = '{ p_werks }'|. ENDIF.
    READ TABLE lt_flds TRANSPORTING NO FIELDS WITH KEY fieldname = 'MATNR'.
    CHECK sy-subrc = 0.

    CREATE DATA lr_tab TYPE STANDARD TABLE OF (lv_tab).
    ASSIGN lr_tab->* TO <t>.
    TRY.
        SELECT * FROM (lv_tab) INTO TABLE <t> WHERE (lv_where).
      CATCH cx_root INTO lx_err.
        MESSAGE |{ lv_tab }: { lx_err->get_text( ) }| TYPE 'S' DISPLAY LIKE 'W'.
        CONTINUE.
    ENDTRY.
    CHECK <t> IS NOT INITIAL.

    CLEAR lt_key.
    LOOP AT <t> ASSIGNING <w>.
      ASSIGN COMPONENT 'MATNR' OF STRUCTURE <w> TO <f>.
      CHECK <f> IN s_matnr.
      ls_key-matnr = <f>.
      ASSIGN COMPONENT 'KNUMH' OF STRUCTURE <w> TO <f>.
      ls_key-knumh = <f>.
      APPEND ls_key TO lt_key.
    ENDLOOP.
    CHECK lt_key IS NOT INITIAL.

    SELECT * FROM konp INTO TABLE lt_konp
      FOR ALL ENTRIES IN lt_key
      WHERE knumh = lt_key-knumh
        AND loevm_ko = space.

    LOOP AT lt_key INTO ls_key.
      LOOP AT lt_konp INTO ls_konp WHERE knumh = ls_key-knumh.
        ls_sp-matnr = ls_key-matnr.
        ls_sp-kmein = ls_konp-kmein.
        ls_sp-kbetr = ls_konp-kbetr.
        ls_sp-kpein = ls_konp-kpein.
        ls_sp-konwa = ls_konp-konwa.
        INSERT ls_sp INTO TABLE ct_sp.      " already there from a more specific table: kept
        EXIT.
      ENDLOOP.
    ENDLOOP.
  ENDLOOP.
ENDFORM.

*&---------------------------------------------------------------------*
*& Reads today's customer discounts of the branch from ZPOS_EXCEL_CMPG
*& into GT_DISC (material + unit -> discount amount).
FORM read_discounts.
  TYPES: BEGIN OF ty_cmpg,
           matnr             TYPE mara-matnr,
           uom               TYPE mara-meins,
           customer_discount TYPE netwr,
           validity_from     TYPE d,
         END OF ty_cmpg.
  DATA: lt_cmpg  TYPE STANDARD TABLE OF ty_cmpg,
        ls_cmpg  TYPE ty_cmpg,
        ls_disc  TYPE ty_disc,
        lv_store TYPE char4.

  lv_store = p_werks.
  SELECT matnr uom customer_discount validity_from
    FROM zpos_excel_cmpg
    INTO CORRESPONDING FIELDS OF TABLE lt_cmpg
    WHERE store_code        = lv_store
      AND customer_discount > 0
      AND validity_from    <= sy-datum
      AND validity_to      >= sy-datum.

  SORT lt_cmpg BY matnr uom validity_from DESCENDING.
  LOOP AT lt_cmpg INTO ls_cmpg.
    ls_disc-matnr = ls_cmpg-matnr.
    ls_disc-uom   = ls_cmpg-uom.
    ls_disc-disc  = ls_cmpg-customer_discount.
    INSERT ls_disc INTO TABLE gt_disc.     " duplicate key: newest already in
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
*&                    P_VKORG = Sales org (optional),
*&                    P_VTWEG = Distribution channel (optional),
*&                    P_ALV = Show list (ALV),
*&                    P_PC = Save to PC,  P_FILE = PC file,
*&                    P_APPL = Save to app. server,
*&                    P_AFILE = App. server file (AL11)
*&
*& Background job: SM36, step = this report with a variant for the
*& branch. It writes to P_AFILE; make sure that folder exists (AL11).
*& Needs ABAP 7.40 or newer (S/4HANA or ECC EhP7+).
*&---------------------------------------------------------------------*
