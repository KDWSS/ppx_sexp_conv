open! Base
open! Ppxlib
open Ast_builder.Default
open Helpers
open Lifted.Monad_infix

(* Generates the signature for type conversion from S-expressions *)
module Sig_generate_of_sexp = struct
  let type_of_of_sexp ~loc t =
    let loc = { loc with loc_ghost = true } in
    [%type: Sexplib0.Sexp.t -> [%t t]]
  ;;

  let mk_type td = combinator_type_of_type_declaration td ~f:type_of_of_sexp

  let sig_of_td with_poly td =
    let of_sexp_type = mk_type td in
    let loc = td.ptype_loc in
    let of_sexp_item =
      psig_value
        ~loc
        (value_description
           ~loc
           ~name:(Located.map (fun s -> s ^ "_of_sexp") td.ptype_name)
           ~type_:of_sexp_type
           ~prim:[])
    in
    match with_poly, is_polymorphic_variant td ~sig_:true with
    | true, `Surely_not ->
      Location.raise_errorf
        ~loc
        "Sig_generate_of_sexp.sig_of_td: sexp_poly annotation but type is surely not a \
         polymorphic variant"
    | false, (`Surely_not | `Maybe) -> [ of_sexp_item ]
    | (true | false), `Definitely | true, `Maybe ->
      [ of_sexp_item
      ; psig_value
          ~loc
          (value_description
             ~loc
             ~name:(Located.map (fun s -> "__" ^ s ^ "_of_sexp__") td.ptype_name)
             ~type_:of_sexp_type
             ~prim:[])
      ]
  ;;

  let mk_sig ~poly ~loc:_ ~path:_ (_rf, tds) = List.concat_map tds ~f:(sig_of_td poly)
end

module Str_generate_of_sexp = struct
  let with_error_source ~loc ~full_type_name make_body =
    let lifted =
      let name = lazy (gen_symbol ~prefix:"error_source" ()) in
      make_body ~error_source:(fun ~loc -> evar ~loc (force name))
      >>| fun body ->
      match Lazy.is_val name with
      | false ->
        (* no references to [name], no need to define it *)
        body
      | true ->
        (* add a definition for [name] *)
        [%expr
          let [%p pvar ~loc (force name)] = [%e estring ~loc full_type_name] in
          [%e body]]
    in
    Lifted.let_bind_user_expressions lifted ~loc
  ;;

  (* Utility functions for polymorphic variants *)

  (* Handle backtracking when variants do not match *)
  let handle_no_variant_match loc expr =
    [ [%pat? Sexplib0.Sexp_conv_error.No_variant_match] --> expr ]
  ;;

  (* Generate code depending on whether to generate a match for the last
     case of matching a variant *)
  let handle_variant_match_last loc ~match_last matches =
    match match_last, matches with
    | true, [ { pc_lhs = _; pc_guard = None; pc_rhs = expr } ]
    | _, [ { pc_lhs = [%pat? _]; pc_guard = None; pc_rhs = expr } ] -> expr
    | _ -> pexp_match ~loc [%expr atom] matches
  ;;

  (* Generate code for matching malformed S-expressions *)
  let mk_variant_other_matches ~error_source loc rev_els call =
    let coll_structs acc (loc, cnstr) =
      (pstring ~loc cnstr
       -->
       match call with
       | `ptag_no_args ->
         [%expr Sexplib0.Sexp_conv_error.ptag_no_args [%e error_source ~loc] _sexp]
       | `ptag_takes_args ->
         [%expr Sexplib0.Sexp_conv_error.ptag_takes_args [%e error_source ~loc] _sexp])
      :: acc
    in
    let exc_no_variant_match =
      [%pat? _] --> [%expr Sexplib0.Sexp_conv_error.no_variant_match ()]
    in
    List.fold_left ~f:coll_structs ~init:[ exc_no_variant_match ] rev_els
  ;;

  (* Split the row fields of a variant type into lists of atomic variants,
     structured variants, atomic variants + included variant types,
     and structured variants + included variant types. *)
  let split_row_field ~loc (atoms, structs, ainhs, sinhs) row_field =
    match row_field.prf_desc with
    | Rtag ({ txt = cnstr; _ }, true, []) ->
      let tpl = loc, cnstr in
      tpl :: atoms, structs, `A tpl :: ainhs, sinhs
    | Rtag ({ txt = cnstr; _ }, false, [ tp ]) ->
      let loc = tp.ptyp_loc in
      atoms, (loc, cnstr) :: structs, ainhs, `S (loc, cnstr, tp, row_field) :: sinhs
    | Rinherit inh ->
      let iinh = `I inh in
      atoms, structs, iinh :: ainhs, iinh :: sinhs
    | Rtag (_, true, [ _ ]) | Rtag (_, _, _ :: _ :: _) ->
      Location.raise_errorf ~loc "split_row_field/&"
    | Rtag (_, false, []) -> assert false
  ;;

  let type_constr_of_sexp ?(internal = false) id args =
    type_constr_conv id args ~f:(fun s ->
      let s = s ^ "_of_sexp" in
      if internal then "__" ^ s ^ "__" else s)
  ;;

  (* Conversion of types *)
  let rec type_of_sexp ~error_source ~typevar_handling ?full_type ?(internal = false) typ
    : Conversion.t
    =
    let loc = typ.ptyp_loc in
    match typ with
    | _ when Option.is_some (Attribute.get Attrs.opaque typ) ->
      Conversion.of_reference_exn [%expr Sexplib0.Sexp_conv.opaque_of_sexp]
    | [%type: [%t? _] sexp_opaque] | [%type: _] ->
      Conversion.of_reference_exn [%expr Sexplib0.Sexp_conv.opaque_of_sexp]
    | [%type: [%t? ty1] sexp_list] ->
      let arg1 =
        Conversion.to_expression ~loc (type_of_sexp ~error_source ~typevar_handling ty1)
      in
      Conversion.of_reference_exn [%expr Sexplib0.Sexp_conv.list_of_sexp [%e arg1]]
    | [%type: [%t? ty1] sexp_array] ->
      let arg1 =
        Conversion.to_expression ~loc (type_of_sexp ~error_source ~typevar_handling ty1)
      in
      Conversion.of_reference_exn [%expr Sexplib0.Sexp_conv.array_of_sexp [%e arg1]]
    | { ptyp_desc = Ptyp_tuple tp; _ } ->
      Conversion.of_lambda (tuple_of_sexp ~error_source ~typevar_handling (loc, tp))
    | { ptyp_desc = Ptyp_var parm; _ } ->
      (match typevar_handling with
       | `ok -> Conversion.of_reference_exn (evar ~loc ("_of_" ^ parm))
       | `disallowed_in_type_expr ->
         Location.raise_errorf
           ~loc
           "Type variables not allowed in [%%of_sexp: ]. Please use locally abstract \
            types instead.")
    | { ptyp_desc = Ptyp_constr (id, args); _ } ->
      let args =
        List.map args ~f:(fun arg ->
          Conversion.to_expression
            ~loc
            (type_of_sexp ~error_source ~typevar_handling arg))
      in
      Conversion.of_reference_exn (type_constr_of_sexp ~loc ~internal id args)
    | { ptyp_desc = Ptyp_arrow (_, _, _); _ } ->
      Conversion.of_reference_exn [%expr Sexplib0.Sexp_conv.fun_of_sexp]
    | { ptyp_desc = Ptyp_variant (row_fields, Closed, _); _ } ->
      variant_of_sexp ~error_source ~typevar_handling ?full_type (loc, row_fields)
    | { ptyp_desc = Ptyp_poly (parms, poly_tp); _ } ->
      poly_of_sexp ~error_source ~typevar_handling parms poly_tp
    | { ptyp_desc = Ptyp_variant (_, Open, _); _ }
    | { ptyp_desc = Ptyp_object (_, _); _ }
    | { ptyp_desc = Ptyp_class (_, _); _ }
    | { ptyp_desc = Ptyp_alias (_, _); _ }
    | { ptyp_desc = Ptyp_package _; _ }
    | { ptyp_desc = Ptyp_extension _; _ } ->
      Location.raise_errorf ~loc "Type unsupported for ppx [of_sexp] conversion"

  (* Conversion of tuples *)
  and tuple_of_sexp ~error_source ~typevar_handling (loc, tps) =
    let fps = List.map ~f:(type_of_sexp ~error_source ~typevar_handling) tps in
    let ({ bindings; arguments; converted } : Conversion.Apply_all.t) =
      Conversion.apply_all ~loc fps
    in
    let n = List.length fps in
    [ [%pat? Sexplib0.Sexp.List [%p plist ~loc arguments]]
      --> pexp_let ~loc Nonrecursive bindings (pexp_tuple ~loc converted)
    ; [%pat? sexp]
      --> [%expr
        Sexplib0.Sexp_conv_error.tuple_of_size_n_expected
          [%e error_source ~loc]
          [%e eint ~loc n]
          sexp]
    ]

  (* Generate code for matching included variant types *)
  and handle_variant_inh
        ~error_source
        ~typevar_handling
        full_type
        ~match_last
        other_matches
        inh
    =
    let loc = inh.ptyp_loc in
    let func_expr = type_of_sexp ~error_source ~typevar_handling ~internal:true inh in
    let app =
      Conversion.of_reference_exn (Conversion.apply ~loc func_expr [%expr _sexp])
    in
    let match_exc =
      handle_no_variant_match
        loc
        (handle_variant_match_last loc ~match_last other_matches)
    in
    let new_other_matches =
      [ [%pat? _]
        --> pexp_try
              ~loc
              [%expr
                ([%e Conversion.to_expression ~loc app]
                 :> [%t replace_variables_by_underscores full_type])]
              match_exc
      ]
    in
    new_other_matches, true

  (* Generate code for matching atomic variants *)
  and mk_variant_match_atom
        ~error_source
        ~typevar_handling
        loc
        full_type
        rev_atoms_inhs
        rev_structs
    =
    let coll (other_matches, match_last) = function
      | `A (loc, cnstr) ->
        let new_match = pstring ~loc cnstr --> pexp_variant ~loc cnstr None in
        new_match :: other_matches, false
      | `I inh ->
        handle_variant_inh
          ~error_source
          ~typevar_handling
          full_type
          ~match_last
          other_matches
          inh
    in
    let other_matches =
      mk_variant_other_matches ~error_source loc rev_structs `ptag_takes_args
    in
    let match_atoms_inhs, match_last =
      List.fold_left ~f:coll ~init:(other_matches, false) rev_atoms_inhs
    in
    handle_variant_match_last loc ~match_last match_atoms_inhs

  (* Variant conversions *)

  (* Match arguments of constructors (variants or sum types) *)
  and mk_cnstr_args_match ~error_source ~typevar_handling ~loc ~is_variant cnstr tps row =
    let cnstr vars_expr =
      if is_variant
      then pexp_variant ~loc cnstr (Some vars_expr)
      else pexp_construct ~loc (Located.lident ~loc cnstr) (Some vars_expr)
    in
    match tps with
    | [ tp ]
      when Option.is_some
             (match row with
              | `Row r -> Attribute.get Attrs.list_poly r
              | `Constructor c -> Attribute.get Attrs.list_variant c) ->
      (match tp with
       | [%type: [%t? tp] list] ->
         let cnv =
           Conversion.to_expression ~loc (type_of_sexp ~error_source ~typevar_handling tp)
         in
         cnstr [%expr Sexplib0.Sexp_conv.list_map [%e cnv] sexp_args]
       | _ ->
         (match row with
          | `Row _ -> Attrs.invalid_attribute ~loc Attrs.list_poly "_ list"
          | `Constructor _ -> Attrs.invalid_attribute ~loc Attrs.list_variant "_ list"))
    | [ [%type: [%t? tp] sexp_list] ] ->
      let cnv =
        Conversion.to_expression ~loc (type_of_sexp ~error_source ~typevar_handling tp)
      in
      cnstr [%expr Sexplib0.Sexp_conv.list_map [%e cnv] sexp_args]
    | _ ->
      let bindings, patts, good_arg_match =
        let fps = List.map ~f:(type_of_sexp ~error_source ~typevar_handling) tps in
        let ({ bindings; arguments; converted } : Conversion.Apply_all.t) =
          Conversion.apply_all ~loc fps
        in
        let good_arg_match = cnstr (pexp_tuple ~loc converted) in
        bindings, arguments, good_arg_match
      in
      [%expr
        match sexp_args with
        | [%p plist ~loc patts] -> [%e pexp_let ~loc Nonrecursive bindings good_arg_match]
        | _ ->
          [%e
            if is_variant
            then
              [%expr
                Sexplib0.Sexp_conv_error.ptag_incorrect_n_args
                  [%e error_source ~loc]
                  _tag
                  _sexp]
            else
              [%expr
                Sexplib0.Sexp_conv_error.stag_incorrect_n_args
                  [%e error_source ~loc]
                  _tag
                  _sexp]]]

  (* Generate code for matching structured variants *)
  and mk_variant_match_struct
        ~error_source
        ~typevar_handling
        loc
        full_type
        rev_structs_inhs
        rev_atoms
    =
    let has_structs_ref = ref false in
    let coll (other_matches, match_last) = function
      | `S (loc, cnstr, tp, row) ->
        has_structs_ref := true;
        let expr =
          mk_cnstr_args_match
            ~error_source
            ~typevar_handling
            ~loc:tp.ptyp_loc
            ~is_variant:true
            cnstr
            [ tp ]
            (`Row row)
        in
        let new_match = [%pat? [%p pstring ~loc cnstr] as _tag] --> expr in
        new_match :: other_matches, false
      | `I inh ->
        handle_variant_inh
          ~error_source
          ~typevar_handling
          full_type
          ~match_last
          other_matches
          inh
    in
    let other_matches =
      mk_variant_other_matches ~error_source loc rev_atoms `ptag_no_args
    in
    let match_structs_inhs, match_last =
      List.fold_left ~f:coll ~init:(other_matches, false) rev_structs_inhs
    in
    handle_variant_match_last loc ~match_last match_structs_inhs, !has_structs_ref

  (* Generate code for handling atomic and structured variants (i.e. not
     included variant types) *)
  and handle_variant_tag ~error_source ~typevar_handling loc full_type row_field_list =
    let rev_atoms, rev_structs, rev_atoms_inhs, rev_structs_inhs =
      List.fold_left ~f:(split_row_field ~loc) ~init:([], [], [], []) row_field_list
    in
    let match_struct, has_structs =
      mk_variant_match_struct
        ~error_source
        ~typevar_handling
        loc
        full_type
        rev_structs_inhs
        rev_atoms
    in
    let maybe_sexp_args_patt = if has_structs then [%pat? sexp_args] else [%pat? _] in
    [ [%pat? Sexplib0.Sexp.Atom atom as _sexp]
      --> mk_variant_match_atom
            ~error_source
            ~typevar_handling
            loc
            full_type
            rev_atoms_inhs
            rev_structs
    ; [%pat?
             Sexplib0.Sexp.List (Sexplib0.Sexp.Atom atom :: [%p maybe_sexp_args_patt]) as _sexp]
      --> match_struct
    ; [%pat? Sexplib0.Sexp.List (Sexplib0.Sexp.List _ :: _) as sexp]
      --> [%expr
        Sexplib0.Sexp_conv_error.nested_list_invalid_poly_var
          [%e error_source ~loc]
          sexp]
    ; [%pat? Sexplib0.Sexp.List [] as sexp]
      --> [%expr
        Sexplib0.Sexp_conv_error.empty_list_invalid_poly_var
          [%e error_source ~loc]
          sexp]
    ]

  (* Generate matching code for variants *)
  and variant_of_sexp ~error_source ~typevar_handling ?full_type (loc, row_fields) =
    let is_contained, full_type =
      match full_type with
      | None -> true, ptyp_variant ~loc row_fields Closed None
      | Some full_type -> false, full_type
    in
    let top_match =
      match row_fields with
      | { prf_desc = Rinherit inh; _ } :: rest ->
        let rec loop inh row_fields =
          let call =
            [%expr
              ([%e
                Conversion.to_expression
                  ~loc
                  (type_of_sexp ~error_source ~typevar_handling ~internal:true inh)]
                 sexp
               :> [%t replace_variables_by_underscores full_type])]
          in
          match row_fields with
          | [] -> call
          | h :: t ->
            let expr =
              match h.prf_desc with
              | Rinherit inh -> loop inh t
              | _ ->
                let rftag_matches =
                  handle_variant_tag
                    ~error_source
                    ~typevar_handling
                    loc
                    full_type
                    row_fields
                in
                pexp_match ~loc [%expr sexp] rftag_matches
            in
            pexp_try ~loc call (handle_no_variant_match loc expr)
        in
        [ [%pat? sexp] --> loop inh rest ]
      | _ :: _ ->
        handle_variant_tag ~error_source ~typevar_handling loc full_type row_fields
      | [] ->
        Location.raise_errorf
          ~loc
          "of_sexp is not supported for empty polymorphic variants (impossible?)"
    in
    if is_contained
    then
      Conversion.of_lambda
        [ [%pat? sexp]
          --> [%expr
            try [%e pexp_match ~loc [%expr sexp] top_match] with
            | Sexplib0.Sexp_conv_error.No_variant_match ->
              Sexplib0.Sexp_conv_error.no_matching_variant_found
                [%e error_source ~loc]
                sexp]
        ]
    else Conversion.of_lambda top_match

  and poly_of_sexp ~error_source ~typevar_handling parms tp =
    let loc = tp.ptyp_loc in
    let bindings =
      let mk_binding parm =
        value_binding
          ~loc
          ~pat:(pvar ~loc ("_of_" ^ parm.txt))
          ~expr:
            [%expr
              fun sexp ->
                Sexplib0.Sexp_conv_error.record_poly_field_value
                  [%e error_source ~loc]
                  sexp]
      in
      List.map ~f:mk_binding parms
    in
    Conversion.bind (type_of_sexp ~error_source ~typevar_handling tp) bindings
  ;;

  (* Generate code for extracting record fields *)
  let mk_extract_fields ~error_source ~typevar_handling ~allow_extra_fields (loc, flds) =
    let rec loop inits cases = function
      | [] -> inits, cases
      | ld :: more_flds ->
        let loc = ld.pld_name.loc in
        let nm = ld.pld_name.txt in
        (match Record_field_attrs.Of_sexp.create ~loc ld, ld.pld_type with
         | Sexp_bool, _ ->
           let inits = [%expr false] :: inits in
           let cases =
             (pstring ~loc nm
              --> [%expr
                if ![%e evar ~loc (nm ^ "_field")]
                then duplicates := field_name :: !duplicates
                else (
                  match _field_sexps with
                  | [] -> [%e evar ~loc (nm ^ "_field")] := true
                  | _ :: _ ->
                    Sexplib0.Sexp_conv_error.record_sexp_bool_with_payload
                      [%e error_source ~loc]
                      sexp)])
             :: cases
           in
           loop inits cases more_flds
         | Sexp_option tp, _
         | ( ( Specific Required
             | Specific (Default _)
             | Omit_nil | Sexp_array _ | Sexp_list _ )
           , tp ) ->
           let inits = [%expr Stdlib.Option.None] :: inits in
           let unrolled =
             Conversion.apply
               ~loc
               (type_of_sexp ~error_source ~typevar_handling tp)
               [%expr _field_sexp]
           in
           let cases =
             (pstring ~loc nm
              --> [%expr
                match ![%e evar ~loc (nm ^ "_field")] with
                | Stdlib.Option.None ->
                  let _field_sexp = _field_sexp () in
                  let fvalue = [%e unrolled] in
                  [%e evar ~loc (nm ^ "_field")] := Stdlib.Option.Some fvalue
                | Stdlib.Option.Some _ -> duplicates := field_name :: !duplicates])
             :: cases
           in
           loop inits cases more_flds)
    in
    let handle_extra =
      [ ([%pat? _]
         -->
         if allow_extra_fields
         then [%expr ()]
         else
           [%expr
             if !Sexplib0.Sexp_conv.record_check_extra_fields
             then extra := field_name :: !extra
             else ()])
      ]
    in
    loop [] handle_extra (List.rev flds)
  ;;

  (* Generate code for handling the result of matching record fields *)
  let mk_handle_record_match_result
        ~error_source
        ~typevar_handling
        has_poly
        (loc, flds)
        ~wrap_expr
    =
    let has_nonopt_fields = ref false in
    let res_tpls, bi_lst, good_patts =
      let rec loop ((res_tpls, bi_lst, good_patts) as acc) = function
        | ({ pld_name = { txt = nm; loc }; _ } as ld) :: more_flds ->
          let fld = [%expr ![%e evar ~loc (nm ^ "_field")]] in
          let mk_default loc =
            bi_lst, [%pat? [%p pvar ~loc (nm ^ "_value")]] :: good_patts
          in
          let new_bi_lst, new_good_patts =
            match Record_field_attrs.Of_sexp.create ~loc ld with
            | Specific (Default _)
            | Sexp_bool | Sexp_option _ | Sexp_list _ | Sexp_array _ | Omit_nil ->
              mk_default loc
            | Specific Required ->
              has_nonopt_fields := true;
              ( [%expr
                Sexplib0.Sexp_conv.( = ) [%e fld] Stdlib.Option.None
              , [%e estring ~loc nm]]
                :: bi_lst
              , [%pat? Stdlib.Option.Some [%p pvar ~loc (nm ^ "_value")]] :: good_patts )
          in
          let acc = [%expr [%e fld]] :: res_tpls, new_bi_lst, new_good_patts in
          loop acc more_flds
        | [] -> acc
      in
      loop ([], [], []) (List.rev flds)
    in
    let cnvt_value ld =
      let nm = ld.pld_name.txt in
      match Record_field_attrs.Of_sexp.create ~loc ld with
      | Sexp_list _ ->
        [%expr
          match [%e evar ~loc (nm ^ "_value")] with
          | Stdlib.Option.None -> []
          | Stdlib.Option.Some v -> v]
        |> Lifted.return
      | Sexp_array _ ->
        [%expr
          match [%e evar ~loc (nm ^ "_value")] with
          | Stdlib.Option.None -> [||]
          | Stdlib.Option.Some v -> v]
        |> Lifted.return
      | Specific (Default lifted_default) ->
        lifted_default
        >>= fun default ->
        [%expr
          match [%e evar ~loc (nm ^ "_value")] with
          | Stdlib.Option.None -> [%e default]
          | Stdlib.Option.Some v -> v]
        |> Lifted.return
      | Sexp_bool | Sexp_option _ | Specific Required ->
        evar ~loc (nm ^ "_value") |> Lifted.return
      | Omit_nil ->
        [%expr
          match [%e evar ~loc (nm ^ "_value")] with
          | Stdlib.Option.Some v -> v
          | Stdlib.Option.None ->
            (* We change the exception so it contains a sub-sexp of the
               initial sexp, otherwise sexplib won't find the source location
               for the error. *)
            (try
               [%e
                 Conversion.apply
                   ~loc
                   (type_of_sexp ~error_source ~typevar_handling ld.pld_type)
                   [%expr Sexplib0.Sexp.List []]]
             with
             | Sexplib0.Sexp_conv_error.Of_sexp_error (e, _sexp) ->
               raise (Sexplib0.Sexp_conv_error.Of_sexp_error (e, sexp)))]
        |> Lifted.return
    in
    let lifted_match_good_expr =
      if has_poly
      then List.map ~f:cnvt_value flds |> Lifted.all >>| pexp_tuple ~loc
      else (
        let cnvt ld =
          cnvt_value ld >>| fun field -> Located.lident ~loc ld.pld_name.txt, field
        in
        List.map ~f:cnvt flds
        |> Lifted.all
        >>| fun fields -> wrap_expr (pexp_record ~loc fields None))
    in
    let expr = pexp_tuple ~loc res_tpls in
    let patt = ppat_tuple ~loc good_patts in
    lifted_match_good_expr
    >>| fun match_good_expr ->
    if !has_nonopt_fields
    then
      pexp_match
        ~loc
        expr
        [ patt --> match_good_expr
        ; [%pat? _]
          --> [%expr
            Sexplib0.Sexp_conv_error.record_undefined_elements
              [%e error_source ~loc]
              sexp
              [%e elist ~loc bi_lst]]
        ]
    else pexp_match ~loc expr [ patt --> match_good_expr ]
  ;;

  (* Generate code for converting record fields *)
  let mk_cnv_fields
        ~error_source
        ~typevar_handling
        ~allow_extra_fields
        has_poly
        (loc, flds)
        ~wrap_expr
    =
    let expr_ref_inits, mc_fields =
      mk_extract_fields ~error_source ~typevar_handling ~allow_extra_fields (loc, flds)
    in
    let field_refs =
      List.map2_exn
        flds
        expr_ref_inits
        ~f:(fun { pld_name = { txt = name; loc }; _ } init ->
          value_binding
            ~loc
            ~pat:(pvar ~loc (name ^ "_field"))
            ~expr:[%expr ref [%e init]])
    in
    mk_handle_record_match_result
      ~error_source
      ~typevar_handling
      has_poly
      (loc, flds)
      ~wrap_expr
    >>| fun result_expr ->
    pexp_let
      ~loc
      Nonrecursive
      (field_refs
       @ [ value_binding ~loc ~pat:[%pat? duplicates] ~expr:[%expr ref []]
         ; value_binding ~loc ~pat:[%pat? extra] ~expr:[%expr ref []]
         ])
      [%expr
        let rec iter =
          [%e
            pexp_function
              ~loc
              [ [%pat?
                       Sexplib0.Sexp.List
                       (Sexplib0.Sexp.Atom field_name :: (([] | [ _ ]) as _field_sexps))
                     :: tail]
                --> [%expr
                  let _field_sexp () =
                    match _field_sexps with
                    | [ x ] -> x
                    | [] ->
                      Sexplib0.Sexp_conv_error.record_only_pairs_expected
                        [%e error_source ~loc]
                        sexp
                    | _ -> assert false
                  in
                  [%e pexp_match ~loc [%expr field_name] mc_fields];
                  iter tail]
              ; [%pat? ((Sexplib0.Sexp.Atom _ | Sexplib0.Sexp.List _) as sexp) :: _]
                --> [%expr
                  Sexplib0.Sexp_conv_error.record_only_pairs_expected
                    [%e error_source ~loc]
                    sexp]
              ; [%pat? []] --> [%expr ()]
              ]]
        in
        iter field_sexps;
        match !duplicates with
        | _ :: _ ->
          Sexplib0.Sexp_conv_error.record_duplicate_fields
            [%e error_source ~loc]
            !duplicates
            sexp
        | [] ->
          (match !extra with
           | _ :: _ ->
             Sexplib0.Sexp_conv_error.record_extra_fields
               [%e error_source ~loc]
               !extra
               sexp
           | [] -> [%e result_expr])]
  ;;

  let is_poly (_, flds) =
    List.exists flds ~f:(function
      | { pld_type = { ptyp_desc = Ptyp_poly _; _ }; _ } -> true
      | _ -> false)
  ;;

  let label_declaration_list_of_sexp
        ~error_source
        ~typevar_handling
        ~allow_extra_fields
        loc
        flds
        ~wrap_expr
    =
    let has_poly = is_poly (loc, flds) in
    mk_cnv_fields
      ~error_source
      ~typevar_handling
      ~allow_extra_fields
      has_poly
      (loc, flds)
      ~wrap_expr
    >>| fun cnv_fields ->
    if has_poly
    then (
      let patt =
        ppat_tuple
          ~loc
          (List.map flds ~f:(fun { pld_name = { txt = name; loc }; _ } -> pvar ~loc name))
      in
      let record_def =
        wrap_expr
          (pexp_record
             ~loc
             (List.map flds ~f:(fun { pld_name = { txt = name; loc }; _ } ->
                Located.lident ~loc name, evar ~loc name))
             None)
      in
      pexp_let
        ~loc
        Nonrecursive
        [ value_binding ~loc ~pat:patt ~expr:cnv_fields ]
        record_def)
    else cnv_fields
  ;;

  (* Generate matching code for records *)
  let record_of_sexp ~error_source ~typevar_handling ~allow_extra_fields (loc, flds) =
    label_declaration_list_of_sexp
      ~error_source
      ~typevar_handling
      ~allow_extra_fields
      loc
      flds
      ~wrap_expr:(fun x -> x)
    >>| fun success_expr ->
    Conversion.of_lambda
      [ [%pat? Sexplib0.Sexp.List field_sexps as sexp] --> success_expr
      ; [%pat? Sexplib0.Sexp.Atom _ as sexp]
        --> [%expr
          Sexplib0.Sexp_conv_error.record_list_instead_atom
            [%e error_source ~loc]
            sexp]
      ]
  ;;

  (* Sum type conversions *)

  (* Generate matching code for well-formed S-expressions wrt. sum types *)
  let mk_good_sum_matches ~error_source ~typevar_handling (loc, cds) =
    List.map cds ~f:(fun cd ->
      match cd with
      | { pcd_name = cnstr; pcd_args = Pcstr_record fields; _ } ->
        let lcstr = pstring ~loc (String.uncapitalize cnstr.txt) in
        let str = pstring ~loc cnstr.txt in
        label_declaration_list_of_sexp
          ~error_source
          ~typevar_handling
          ~allow_extra_fields:
            (Option.is_some (Attribute.get Attrs.allow_extra_fields_cd cd))
          loc
          fields
          ~wrap_expr:(fun e ->
            pexp_construct ~loc (Located.lident ~loc cnstr.txt) (Some e))
        >>| fun expr ->
        [%pat?
               Sexplib0.Sexp.List
               (Sexplib0.Sexp.Atom (([%p lcstr] | [%p str]) as _tag) :: field_sexps) as
          sexp]
        --> expr
      | { pcd_name = cnstr; pcd_args = Pcstr_tuple []; _ } ->
        Attrs.fail_if_allow_extra_field_cd ~loc cd;
        let lcstr = pstring ~loc (String.uncapitalize cnstr.txt) in
        let str = pstring ~loc cnstr.txt in
        [%pat? Sexplib0.Sexp.Atom ([%p lcstr] | [%p str])]
        --> pexp_construct ~loc (Located.lident ~loc cnstr.txt) None
        |> Lifted.return
      | { pcd_name = cnstr; pcd_args = Pcstr_tuple (_ :: _ as tps); _ } ->
        Attrs.fail_if_allow_extra_field_cd ~loc cd;
        let lcstr = pstring ~loc (String.uncapitalize cnstr.txt) in
        let str = pstring ~loc cnstr.txt in
        [%pat?
               Sexplib0.Sexp.List
               (Sexplib0.Sexp.Atom (([%p lcstr] | [%p str]) as _tag) :: sexp_args) as _sexp]
        --> mk_cnstr_args_match
              ~error_source
              ~typevar_handling
              ~loc
              ~is_variant:false
              cnstr.txt
              tps
              (`Constructor cd)
        |> Lifted.return)
  ;;

  (* Generate matching code for malformed S-expressions with good tags
     wrt. sum types *)
  let mk_bad_sum_matches ~error_source (loc, cds) =
    List.map cds ~f:(function
      | { pcd_name = cnstr; pcd_args = Pcstr_tuple []; _ } ->
        let lcstr = pstring ~loc (String.uncapitalize cnstr.txt) in
        let str = pstring ~loc cnstr.txt in
        [%pat?
               Sexplib0.Sexp.List (Sexplib0.Sexp.Atom ([%p lcstr] | [%p str]) :: _) as sexp]
        --> [%expr Sexplib0.Sexp_conv_error.stag_no_args [%e error_source ~loc] sexp]
      | { pcd_name = cnstr; pcd_args = Pcstr_tuple (_ :: _) | Pcstr_record _; _ } ->
        let lcstr = pstring ~loc (String.uncapitalize cnstr.txt) in
        let str = pstring ~loc cnstr.txt in
        [%pat? Sexplib0.Sexp.Atom ([%p lcstr] | [%p str]) as sexp]
        --> [%expr Sexplib0.Sexp_conv_error.stag_takes_args [%e error_source ~loc] sexp])
  ;;

  (* Generate matching code for sum types *)
  let sum_of_sexp ~error_source ~typevar_handling (loc, alts) =
    [ mk_good_sum_matches ~error_source ~typevar_handling (loc, alts) |> Lifted.all
    ; mk_bad_sum_matches ~error_source (loc, alts) |> Lifted.return
    ; [ [%pat? Sexplib0.Sexp.List (Sexplib0.Sexp.List _ :: _) as sexp]
        --> [%expr
          Sexplib0.Sexp_conv_error.nested_list_invalid_sum [%e error_source ~loc] sexp]
      ; [%pat? Sexplib0.Sexp.List [] as sexp]
        --> [%expr
          Sexplib0.Sexp_conv_error.empty_list_invalid_sum [%e error_source ~loc] sexp]
      ; [%pat? sexp]
        --> [%expr Sexplib0.Sexp_conv_error.unexpected_stag [%e error_source ~loc] sexp]
      ]
      |> Lifted.return
    ]
    |> Lifted.all
    >>| List.concat
    >>| Conversion.of_lambda
  ;;

  (* Empty type *)
  let nil_of_sexp ~error_source loc : Conversion.t =
    Conversion.of_reference_exn
      [%expr Sexplib0.Sexp_conv_error.empty_type [%e error_source ~loc]]
  ;;

  (* Generate code from type definitions *)

  let td_of_sexp ~typevar_handling ~loc:_ ~poly ~path ~rec_flag td =
    let td = name_type_params_in_td td in
    let tps = List.map td.ptype_params ~f:get_type_param_name in
    let { ptype_name = { txt = type_name; loc = _ }; ptype_loc = loc; _ } = td in
    let full_type =
      core_type_of_type_declaration td |> replace_variables_by_underscores
    in
    let is_private =
      match td.ptype_private with
      | Private -> true
      | Public -> false
    in
    if is_private
    then Location.raise_errorf ~loc "of_sexp is not supported for private type";
    let create_internal_function =
      match is_polymorphic_variant td ~sig_:false with
      | `Definitely -> true
      | `Maybe -> poly
      | `Surely_not ->
        if poly
        then
          Location.raise_errorf
            ~loc
            "sexp_poly annotation on a type that is surely not a polymorphic variant";
        false
    in
    let body ~error_source =
      let body =
        match td.ptype_kind with
        | Ptype_variant alts ->
          Attrs.fail_if_allow_extra_field_td ~loc td;
          sum_of_sexp ~error_source ~typevar_handling (td.ptype_loc, alts)
        | Ptype_record lbls ->
          record_of_sexp
            ~error_source
            ~typevar_handling
            ~allow_extra_fields:
              (Option.is_some (Attribute.get Attrs.allow_extra_fields_td td))
            (loc, lbls)
        | Ptype_open ->
          Location.raise_errorf ~loc "ppx_sexp_conv: open types not supported"
        | Ptype_abstract ->
          Attrs.fail_if_allow_extra_field_td ~loc td;
          (match td.ptype_manifest with
           | None -> nil_of_sexp ~error_source td.ptype_loc |> Lifted.return
           | Some ty ->
             type_of_sexp
               ~error_source
               ~full_type
               ~typevar_handling
               ~internal:create_internal_function
               ty
             |> Lifted.return)
      in
      (* Prevent violation of value restriction, problems with recursive types, and
         toplevel effects by eta-expanding function definitions *)
      body >>| Conversion.to_value_expression ~loc
    in
    let external_name = type_name ^ "_of_sexp" in
    let internal_name = "__" ^ type_name ^ "_of_sexp__" in
    let arg_patts, arg_exprs =
      List.unzip
        (List.map
           ~f:(fun tp ->
             let name = "_of_" ^ tp.txt in
             pvar ~loc name, evar ~loc name)
           tps)
    in
    let full_type_name = Printf.sprintf "%s.%s" path type_name in
    let internal_fun_body =
      if create_internal_function
      then
        Some
          (with_error_source ~loc ~full_type_name (fun ~error_source ->
             body ~error_source
             >>| fun body ->
             eta_reduce_if_possible_and_nonrec ~rec_flag (eabstract ~loc arg_patts body)))
      else None
    in
    let external_fun_body =
      let body_below_lambdas ~error_source =
        if create_internal_function
        then (
          let no_variant_match_mc =
            [ [%pat? Sexplib0.Sexp_conv_error.No_variant_match]
              --> [%expr
                Sexplib0.Sexp_conv_error.no_matching_variant_found
                  [%e error_source ~loc]
                  sexp]
            ]
          in
          let internal_call =
            let internal_expr = evar ~loc internal_name in
            eapply ~loc internal_expr (arg_exprs @ [ [%expr sexp] ])
          in
          let try_with = pexp_try ~loc internal_call no_variant_match_mc in
          [%expr fun sexp -> [%e try_with]] |> Lifted.return)
        else body ~error_source
      in
      let body_with_lambdas ~error_source =
        body_below_lambdas ~error_source
        >>| fun body ->
        eta_reduce_if_possible_and_nonrec ~rec_flag (eabstract ~loc arg_patts body)
      in
      with_error_source ~loc ~full_type_name body_with_lambdas
    in
    let typ = Sig_generate_of_sexp.mk_type td in
    let mk_binding func_name body =
      constrained_function_binding loc td typ ~tps ~func_name body
    in
    let internal_bindings =
      match internal_fun_body with
      | None -> []
      | Some body -> [ mk_binding internal_name body ]
    in
    let external_binding = mk_binding external_name external_fun_body in
    internal_bindings, [ external_binding ]
  ;;

  (* Generate code from type definitions *)
  let tds_of_sexp ~loc ~poly ~path (rec_flag, tds) =
    let typevar_handling = `ok in
    let singleton =
      match tds with
      | [ _ ] -> true
      | _ -> false
    in
    if singleton
    then (
      let rec_flag = really_recursive_respecting_opaque rec_flag tds in
      match rec_flag with
      | Recursive ->
        let bindings =
          List.concat_map tds ~f:(fun td ->
            let internals, externals =
              td_of_sexp ~typevar_handling ~loc ~poly ~path ~rec_flag td
            in
            internals @ externals)
        in
        pstr_value_list ~loc Recursive bindings
      | Nonrecursive ->
        List.concat_map tds ~f:(fun td ->
          let internals, externals =
            td_of_sexp ~typevar_handling ~loc ~poly ~path ~rec_flag td
          in
          pstr_value_list ~loc Nonrecursive internals
          @ pstr_value_list ~loc Nonrecursive externals))
    else (
      let bindings =
        List.concat_map tds ~f:(fun td ->
          let internals, externals =
            td_of_sexp ~typevar_handling ~poly ~loc ~path ~rec_flag td
          in
          internals @ externals)
      in
      pstr_value_list ~loc rec_flag bindings)
  ;;

  let core_type_of_sexp ~path core_type =
    let loc = { core_type.ptyp_loc with loc_ghost = true } in
    let full_type_name =
      Printf.sprintf
        "%s line %i: %s"
        path
        loc.loc_start.pos_lnum
        (string_of_core_type core_type)
    in
    with_error_source ~loc ~full_type_name (fun ~error_source ->
      type_of_sexp ~error_source ~typevar_handling:`disallowed_in_type_expr core_type
      |> Conversion.to_value_expression ~loc
      |> Merlin_helpers.hide_expression
      |> Lifted.return)
  ;;
end
