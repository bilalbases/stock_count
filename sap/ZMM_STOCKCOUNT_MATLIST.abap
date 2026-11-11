*&---------------------------------------------------------------------*
*& Report ZMM_STOCKCOUNT_MATLIST
*&---------------------------------------------------------------------*
*& Downloads the material/article list for the Stock Count app as CSV:
*&   MATERIAL,BARCODE,UOM,DESCRIPTION
*& One row per barcode (EAN/UPC). An article with an EA barcode and a
*& CAR barcode gives two rows. Upload the file in the app with
*& "Upload materials".
*&
*& Output:
*&   - PC file (dialog only), or
*&   - Application server file (AL11). Used automatically in background
*&     jobs (SM36), where a PC download is not possible.
*&
*& Inactive articles are skipped (checkbox, on by default):
*&   - deletion flag at client level (MARA-LVORM) or plant level (MARC-LVORM)
*&   - cross-plant status (MARA-MSTAE) or plant status (MARC-MMSTA) set.
*&     Fill "Inactive status codes" to treat only those codes as inactive;
*&     leave it empty to treat ANY status as inactive.
*&
*& Sources: MARA/MARC, MEAN (all EANs per unit) + MARM-EAN11 (main EAN
*&          per unit), MAKT (description in the logon language).
*&---------------------------------------------------------------------*
REPORT zmm_stockcount_matlist.

TABLES: mara, marc.

TYPES: BEGIN OF ty_row,
         matnr TYPE mara-matnr,
         ean11 TYPE mean-ean11,
         meinh TYPE marm-meinh,
         maktx TYPE makt-maktx,
       END OF ty_row.

DATA: gt_rows  TYPE STANDARD TABLE OF ty_row,
      gt_lines TYPE STANDARD TABLE OF string.

*--- Selection screen --------------------------------------------------
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
  SELECT-OPTIONS: s_werks FOR marc-werks,              " Plant (branch)
                  s_matnr FOR mara-matnr,
                  s_mtart FOR mara-mtart,
                  s_matkl FOR mara-matkl.
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b3 WITH FRAME TITLE TEXT-003.
  PARAMETERS:     p_inact AS CHECKBOX DEFAULT 'X'.     " Skip inactive articles
  SELECT-OPTIONS: s_stat  FOR mara-mstae NO INTERVALS. " Status codes that mean inactive (empty = any)
SELECTION-SCREEN END OF BLOCK b3.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002.
  PARAMETERS: p_pc   RADIOBUTTON GROUP out DEFAULT 'X' USER-COMMAND out,
              p_file TYPE string LOWER CASE DEFAULT 'C:\temp\material_list.csv',
              p_appl RADIOBUTTON GROUP out,
              p_afile TYPE string LOWER CASE DEFAULT '/usr/sap/trans/stockcount/material_list.csv'.
SELECTION-SCREEN END OF BLOCK b2.

AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_file.
  PERFORM f4_file.

*--- Main --------------------------------------------------------------
START-OF-SELECTION.
  PERFORM select_data.
  IF gt_rows IS INITIAL.
    MESSAGE 'No active materials with barcodes found for this selection' TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.
  PERFORM build_csv.

  " Background jobs cannot write to the PC: always use the application server there.
  IF sy-batch = abap_true OR p_appl = abap_true.
    PERFORM write_appl_server.
  ELSE.
    PERFORM download_pc.
  ENDIF.

*&---------------------------------------------------------------------*
FORM select_data.
  TYPES: BEGIN OF ty_mat,
           matnr TYPE mara-matnr,
           lvorm TYPE mara-lvorm,
           mstae TYPE mara-mstae,
           plvor TYPE marc-lvorm,
           mmsta TYPE marc-mmsta,
         END OF ty_mat,
         BEGIN OF ty_key,
           matnr TYPE mara-matnr,
         END OF ty_key.
  DATA: lt_raw  TYPE STANDARD TABLE OF ty_mat,
        lt_mat  TYPE SORTED TABLE OF ty_key WITH UNIQUE KEY matnr,
        ls_key  TYPE ty_key,
        lt_mean TYPE STANDARD TABLE OF ty_row,
        lt_marm TYPE STANDARD TABLE OF ty_row,
        lt_makt TYPE HASHED TABLE OF makt WITH UNIQUE KEY matnr spras,
        ls_makt TYPE makt.
  FIELD-SYMBOLS: <m> TYPE ty_mat,
                 <r> TYPE ty_row.

  " 1. Materials with their deletion flags and statuses
  IF s_werks[] IS INITIAL.
    SELECT matnr lvorm mstae FROM mara
      INTO CORRESPONDING FIELDS OF TABLE lt_raw
      WHERE matnr IN s_matnr
        AND mtart IN s_mtart
        AND matkl IN s_matkl.
  ELSE.
    SELECT a~matnr a~lvorm a~mstae c~lvorm AS plvor c~mmsta
      FROM mara AS a
      INNER JOIN marc AS c ON c~matnr = a~matnr
      INTO CORRESPONDING FIELDS OF TABLE lt_raw
      WHERE a~matnr IN s_matnr
        AND a~mtart IN s_mtart
        AND a~matkl IN s_matkl
        AND c~werks IN s_werks.
  ENDIF.

  " 2. Drop inactive articles. With several plants, an article is kept if it
  "    is active in at least one of them.
  LOOP AT lt_raw ASSIGNING <m>.
    IF p_inact = abap_true.
      IF <m>-lvorm IS NOT INITIAL OR <m>-plvor IS NOT INITIAL.
        CONTINUE.
      ENDIF.
      IF <m>-mstae IS NOT INITIAL AND ( s_stat[] IS INITIAL OR <m>-mstae IN s_stat ).
        CONTINUE.
      ENDIF.
      IF <m>-mmsta IS NOT INITIAL AND ( s_stat[] IS INITIAL OR <m>-mmsta IN s_stat ).
        CONTINUE.
      ENDIF.
    ENDIF.
    ls_key-matnr = <m>-matnr.
    INSERT ls_key INTO TABLE lt_mat.      " duplicates are ignored (sorted unique)
  ENDLOOP.
  FREE lt_raw.
  IF lt_mat IS INITIAL.
    RETURN.
  ENDIF.

  " 3. All barcodes per unit (MEAN) plus the main barcode per unit (MARM)
  SELECT matnr ean11 meinh FROM mean
    INTO CORRESPONDING FIELDS OF TABLE lt_mean
    FOR ALL ENTRIES IN lt_mat
    WHERE matnr = lt_mat-matnr
      AND ean11 <> space.

  SELECT matnr ean11 meinh FROM marm
    INTO CORRESPONDING FIELDS OF TABLE lt_marm
    FOR ALL ENTRIES IN lt_mat
    WHERE matnr = lt_mat-matnr
      AND ean11 <> space.

  APPEND LINES OF lt_mean TO gt_rows.
  APPEND LINES OF lt_marm TO gt_rows.
  SORT gt_rows BY ean11 matnr meinh.
  DELETE ADJACENT DUPLICATES FROM gt_rows COMPARING ean11.   " one row per barcode

  " 4. Descriptions
  SELECT * FROM makt
    INTO TABLE lt_makt
    FOR ALL ENTRIES IN lt_mat
    WHERE matnr = lt_mat-matnr
      AND spras = sy-langu.

  LOOP AT gt_rows ASSIGNING <r>.
    READ TABLE lt_makt INTO ls_makt WITH TABLE KEY matnr = <r>-matnr spras = sy-langu.
    IF sy-subrc = 0.
      <r>-maktx = ls_makt-maktx.
    ENDIF.
  ENDLOOP.

  SORT gt_rows BY matnr meinh ean11.
ENDFORM.

*&---------------------------------------------------------------------*
FORM build_csv.
  DATA: lv_matnr TYPE char40,
        lv_uom   TYPE char3,
        lv_ean   TYPE string,
        lv_line  TYPE string.
  FIELD-SYMBOLS <r> TYPE ty_row.

  APPEND 'MATERIAL,BARCODE,UOM,DESCRIPTION' TO gt_lines.

  LOOP AT gt_rows ASSIGNING <r>.
    " External formats: material without leading zeros, unit as users see it (e.g. EA, CAR)
    CALL FUNCTION 'CONVERSION_EXIT_MATN1_OUTPUT'
      EXPORTING input  = <r>-matnr
      IMPORTING output = lv_matnr.
    CALL FUNCTION 'CONVERSION_EXIT_CUNIT_OUTPUT'
      EXPORTING  input          = <r>-meinh
                 language       = sy-langu
      IMPORTING  output         = lv_uom
      EXCEPTIONS unit_not_found = 1
                 OTHERS         = 2.
    IF sy-subrc <> 0.
      lv_uom = <r>-meinh.
    ENDIF.

    CONDENSE: lv_matnr, lv_uom.
    lv_ean = <r>-ean11.
    CONDENSE lv_ean.
    lv_line = |{ lv_matnr },{ lv_ean },{ lv_uom },|.
    PERFORM csv_field USING <r>-maktx CHANGING lv_line.
    APPEND lv_line TO gt_lines.
  ENDLOOP.
ENDFORM.

*& Quote a text field if it contains a comma or a quote
FORM csv_field USING iv_text TYPE clike CHANGING cv_line TYPE string.
  DATA lv_text TYPE string.
  lv_text = iv_text.
  IF lv_text CA ',"'.
    REPLACE ALL OCCURRENCES OF '"' IN lv_text WITH '""'.
    lv_text = |"{ lv_text }"|.
  ENDIF.
  cv_line = cv_line && lv_text.
ENDFORM.

*&---------------------------------------------------------------------*
FORM download_pc.
  " UTF-8 with BOM so Arabic and other non-English descriptions open correctly
  cl_gui_frontend_services=>gui_download(
    EXPORTING
      filename  = p_file
      filetype  = 'ASC'
      codepage  = '4110'
      write_bom = abap_true
    CHANGING
      data_tab  = gt_lines
    EXCEPTIONS
      OTHERS    = 1 ).
  IF sy-subrc = 0.
    MESSAGE |{ lines( gt_lines ) - 1 } barcodes downloaded to { p_file }| TYPE 'S'.
  ELSE.
    MESSAGE |Download to { p_file } failed| TYPE 'S' DISPLAY LIKE 'E'.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
FORM write_appl_server.
  DATA: lv_line TYPE string,
        lv_msg  TYPE string.

  OPEN DATASET p_afile FOR OUTPUT IN TEXT MODE ENCODING UTF-8 WITH BYTE-ORDER MARK
    MESSAGE lv_msg.
  IF sy-subrc <> 0.
    MESSAGE |Cannot open { p_afile }: { lv_msg }| TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  LOOP AT gt_lines INTO lv_line.
    TRANSFER lv_line TO p_afile.
  ENDLOOP.
  CLOSE DATASET p_afile.

  " Shows in the job log (SM37) and on screen
  MESSAGE |{ lines( gt_lines ) - 1 } barcodes written to { p_afile }| TYPE 'S'.
ENDFORM.

*&---------------------------------------------------------------------*
FORM f4_file.
  DATA: lv_file   TYPE string,
        lv_path   TYPE string,
        lv_full   TYPE string,
        lv_action TYPE i.
  cl_gui_frontend_services=>file_save_dialog(
    EXPORTING
      default_extension = 'csv'
      default_file_name = 'material_list.csv'
      file_filter       = 'CSV files (*.csv)|*.csv'
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
*&   Text symbols:  001 = Selection
*&                  002 = Output
*&                  003 = Inactive articles
*&   Selection texts: S_WERKS = Plant, S_MATNR = Material,
*&     S_MTART = Material type, S_MATKL = Material group,
*&     P_INACT = Skip inactive articles,
*&     S_STAT  = Inactive status codes (empty = any),
*&     P_PC    = Save to PC,            P_FILE  = PC file,
*&     P_APPL  = Save to app. server,   P_AFILE = App. server file (AL11)
*&
*& Background job: SM36, step = this report with a variant that has
*& "Save to app. server" selected (it is used automatically in background
*& anyway). Make sure the folder in P_AFILE exists and is writable (AL11).
*&---------------------------------------------------------------------*
