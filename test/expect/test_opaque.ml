open! Base

type t = (int[@sexp.opaque]) list [@@deriving_inline sexp_grammar]

let _ = fun (_ : t) -> ()

let (t_sexp_grammar : Ppx_sexp_conv_lib.Sexp.Raw_grammar.t) =
  let (_the_generic_group : Ppx_sexp_conv_lib.Sexp.Raw_grammar.generic_group) =
    { implicit_vars = [ "list" ]
    ; ggid          = "\137\239\143\156~\rZ@\176\162LM\160A\163\189"
    ; types         =
        [ ( "t"
          , Apply
              ( Implicit_var 0
              , [ Grammar Ppx_sexp_conv_lib.Sexp.Raw_grammar.opaque_sexp_grammar ] ) )
        ]
    }
  in
  let (_the_group : Ppx_sexp_conv_lib.Sexp.Raw_grammar.group) =
    { gid            = Ppx_sexp_conv_lib.Lazy_group_id.create ()
    ; apply_implicit = [ list_sexp_grammar ]
    ; generic_group  = _the_generic_group
    ; origin         = "test_opaque.ml"
    }
  in
  let (t_sexp_grammar : Ppx_sexp_conv_lib.Sexp.Raw_grammar.t) = Ref ("t", _the_group) in
  t_sexp_grammar
;;

let _ = t_sexp_grammar

[@@@end]
