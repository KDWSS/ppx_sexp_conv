open! Base
open! Ppxlib

let default =
  Attribute.declare
    "sexp.default"
    Attribute.Context.label_declaration
    Ast_pattern.(pstr (pstr_eval __ nil ^:: nil))
    (fun x -> `lift x)
;;

let drop_default =
  Attribute.declare
    "sexp.sexp_drop_default"
    Attribute.Context.label_declaration
    Ast_pattern.(pstr (alt_option (pstr_eval __ nil ^:: nil) nil))
    (function
      | None -> None
      | Some x -> Some (`lift x))
;;

let drop_default_equal =
  Attribute.declare
    "sexp.@sexp_drop_default.equal"
    Attribute.Context.label_declaration
    Ast_pattern.(pstr nil)
    ()
;;

let drop_default_compare =
  Attribute.declare
    "sexp.@sexp_drop_default.compare"
    Attribute.Context.label_declaration
    Ast_pattern.(pstr nil)
    ()
;;

let drop_default_sexp =
  Attribute.declare
    "sexp.@sexp_drop_default.sexp"
    Attribute.Context.label_declaration
    Ast_pattern.(pstr nil)
    ()
;;

let drop_if =
  Attribute.declare
    "sexp.sexp_drop_if"
    Attribute.Context.label_declaration
    Ast_pattern.(pstr (pstr_eval __ nil ^:: nil))
    (fun x -> `lift x)
;;

let opaque =
  Attribute.declare "sexp.opaque" Attribute.Context.core_type Ast_pattern.(pstr nil) ()
;;

let omit_nil =
  Attribute.declare
    "sexp.omit_nil"
    Attribute.Context.label_declaration
    Ast_pattern.(pstr nil)
    ()
;;

let option =
  Attribute.declare
    "sexp.option"
    Attribute.Context.label_declaration
    Ast_pattern.(pstr nil)
    ()
;;

let list =
  Attribute.declare
    "sexp.list"
    Attribute.Context.label_declaration
    Ast_pattern.(pstr nil)
    ()
;;

let array =
  Attribute.declare
    "sexp.array"
    Attribute.Context.label_declaration
    Ast_pattern.(pstr nil)
    ()
;;

let bool =
  Attribute.declare
    "sexp.bool"
    Attribute.Context.label_declaration
    Ast_pattern.(pstr nil)
    ()
;;

let list_variant =
  Attribute.declare
    "sexp.list"
    Attribute.Context.constructor_declaration
    Ast_pattern.(pstr nil)
    ()
;;

let list_exception =
  Attribute.declare "sexp.list" Attribute.Context.type_exception Ast_pattern.(pstr nil) ()
;;

let list_poly =
  Attribute.declare "sexp.list" Attribute.Context.rtag Ast_pattern.(pstr nil) ()
;;

let allow_extra_fields_td =
  Attribute.declare
    "sexp.allow_extra_fields"
    Attribute.Context.type_declaration
    Ast_pattern.(pstr nil)
    ()
;;

let allow_extra_fields_cd =
  Attribute.declare
    "sexp.allow_extra_fields"
    Attribute.Context.constructor_declaration
    Ast_pattern.(pstr nil)
    ()
;;

let invalid_attribute ~loc attr description =
  Location.raise_errorf
    ~loc
    "ppx_sexp_conv: [@%s] is only allowed on type [%s]."
    (Attribute.name attr)
    description
;;

let fail_if_allow_extra_field_cd ~loc x =
  if Option.is_some (Attribute.get allow_extra_fields_cd x)
  then
    Location.raise_errorf
      ~loc
      "ppx_sexp_conv: [@@allow_extra_fields] is only allowed on inline records."
;;

let fail_if_allow_extra_field_td ~loc x =
  if Option.is_some (Attribute.get allow_extra_fields_td x)
  then (
    match x.ptype_kind with
    | Ptype_variant cds
      when List.exists cds ~f:(fun cd ->
        match cd.pcd_args with
        | Pcstr_record _ -> true
        | _ -> false) ->
      Location.raise_errorf
        ~loc
        "ppx_sexp_conv: [@@@@allow_extra_fields] only works on records. For inline \
         records, do: type t = A of { a : int } [@@allow_extra_fields] | B [@@@@deriving \
         sexp]"
    | _ ->
      Location.raise_errorf
        ~loc
        "ppx_sexp_conv: [@@@@allow_extra_fields] is only allowed on records.")
;;
