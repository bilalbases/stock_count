*&---------------------------------------------------------------------*
*& Report ZMM_STOCKCOUNT_MATLIST
*&---------------------------------------------------------------------*
*& Downloads the material list for the Stock Count app as a CSV file:
*&   MATERIAL,BARCODE,UOM,DESCRIPTION
*& One row per barcode (EAN/UPC). A material with an EA barcode and a
*& CAR barcode gives two rows. Upload the file in the app with
*& "Upload materials".
*&
*& Sources: MARA/MARC (materials, optionally per plant),
*&          MEAN (all EANs per unit) + MARM-EAN11 (main EAN per unit),
*&          MAKT (description in the logon language).
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
  PARAMETERS:     p_nodel AS CHECKBOX DEFAULT 'X'.     " Skip materials flagged for deletion
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002.
  PARAMETERS: p_file TYPE string LOWER CASE DEFAULT 'C:\temp\material_list.csv'.
SELECTION-SCREEN END OF BLOCK b2.

AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_file.
  PERFORM f4_file.

*--- Main --------------------------------------------------------------
START-OF-SELECTION.
  PERFORM select_data.
  IF gt_rows IS INITIAL.
    MESSAGE 'No materials with barcodes found for this selection' TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.
  PERFORM build_csv.
  PERFORM download.

*&---------------------------------------------------------------------*
FORM select_data.
  TYPES: BEGIN OF ty_mat,
           matnr TYPE mara-matnr,
         END OF ty_mat.
  DATA: lt_mat  TYPE SORTED TABLE OF ty_mat WITH UNIQUE KEY matnr,
        lt_mean TYPE STANDARD TABLE OF ty_row,
        lt_marm TYPE STANDARD TABLE OF ty_row,
        lt_makt TYPE HASHED TABLE OF makt WITH UNIQUE KEY matnr spras,
        lr_lvorm TYPE RANGE OF mara-lvorm,
        ls_lvorm LIKE LINE OF lr_lvorm.

  " Deletion flag filter: empty range = all materials; with the checkbox only non-deleted ones
  IF p_nodel = abap_true.
    ls_lvorm-sign = 'I'. ls_lvorm-option = 'EQ'. ls_lvorm-low = space.
    APPEND ls_lvorm TO lr_lvorm.
  ENDIF.

  " 1. Materials (restricted to plant if given)
  IF s_werks[] IS INITIAL.
    SELECT matnr FROM mara
      INTO TABLE lt_mat
      WHERE matnr IN s_matnr
        AND mtart IN s_mtart
        AND matkl IN s_matkl
        AND lvorm IN lr_lvorm.
  ELSE.
    SELECT DISTINCT a~matnr FROM mara AS a
      INNER JOIN marc AS c ON c~matnr = a~matnr
      INTO TABLE lt_mat
      WHERE a~matnr IN s_matnr
        AND a~mtart IN s_mtart
        AND a~matkl IN s_matkl
        AND c~werks IN s_werks
        AND a~lvorm IN lr_lvorm
        AND c~lvorm IN lr_lvorm.
  ENDIF.
  IF lt_mat IS INITIAL.
    RETURN.
  ENDIF.

  " 2. All barcodes per unit (MEAN) ...
  SELECT matnr ean11 meinh FROM mean
    INTO CORRESPONDING FIELDS OF TABLE lt_mean
    FOR ALL ENTRIES IN lt_mat
    WHERE matnr = lt_mat-matnr
      AND ean11 <> space.

  " ... plus the main barcode per unit (MARM), in case MEAN is not maintained
  SELECT matnr ean11 meinh FROM marm
    INTO CORRESPONDING FIELDS OF TABLE lt_marm
    FOR ALL ENTRIES IN lt_mat
    WHERE matnr = lt_mat-matnr
      AND ean11 <> space.

  APPEND LINES OF lt_mean TO gt_rows.
  APPEND LINES OF lt_marm TO gt_rows.
  SORT gt_rows BY ean11 matnr meinh.
  DELETE ADJACENT DUPLICATES FROM gt_rows COMPARING ean11.   " one row per barcode

  " 3. Descriptions
  SELECT * FROM makt
    INTO TABLE lt_makt
    FOR ALL ENTRIES IN lt_mat
    WHERE matnr = lt_mat-matnr
      AND spras = sy-langu.

  FIELD-SYMBOLS <r> TYPE ty_row.
  DATA ls_makt TYPE makt.
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
        lv_line  TYPE string.
  FIELD-SYMBOLS <r> TYPE ty_row.

  APPEND 'MATERIAL,BARCODE,UOM,DESCRIPTION' TO gt_lines.

  LOOP AT gt_rows ASSIGNING <r>.
    " External formats: material without leading zeros, unit as shown to users (e.g. EA, CAR)
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
    lv_line = |{ lv_matnr },{ condense( val = <r>-ean11 ) },{ lv_uom },|.
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
FORM download.
  " UTF-8 with BOM so Arabic and other non-English descriptions open correctly
  cl_gui_frontend_services=>gui_download(
    EXPORTING
      filename                = p_file
      filetype                = 'ASC'
      codepage                = '4110'
      write_bom               = abap_true
    CHANGING
      data_tab                = gt_lines
    EXCEPTIONS
      OTHERS                  = 1 ).
  IF sy-subrc = 0.
    MESSAGE |{ lines( gt_lines ) - 1 } barcodes downloaded to { p_file }| TYPE 'S'.
  ELSE.
    MESSAGE |Download to { p_file } failed| TYPE 'S' DISPLAY LIKE 'E'.
  ENDIF.
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
*&   Text symbols:  001 = Selection,  002 = Output file
*&   Selection texts: S_WERKS = Plant, S_MATNR = Material,
*&     S_MTART = Material type, S_MATKL = Material group,
*&     P_NODEL = Skip deleted materials, P_FILE = File name
*&---------------------------------------------------------------------*
