open Ast
open Globals
open Common
open Type
open Typecore
open Typeload
open TypeloadModule
open Error

(* -------------------------------------------------------------------------- *)
(* REMOTING PROXYS *)

let extend_remoting ctx c t p async prot =
	if c.cl_super <> None then typing_error "Cannot extend several classes" p;
	(* remove forbidden packages *)
	let rules = ctx.com.package_rules in
	ctx.com.package_rules <- PMap.foldi (fun key r acc -> match r with Forbidden -> acc | _ -> PMap.add key r acc) rules PMap.empty;
	(* parse module *)
	let path = (t.tpackage,t.tname) in
	let new_name = (if async then "Async_" else "Remoting_") ^ t.tname in
	(* check if the proxy already exists *)
	let t = (try
		load_type_def ctx p (mk_type_path (fst path,new_name))
	with
		Error (Module_not_found _,p2) when p == p2 ->
	(* build it *)
	Common.log ctx.com ("Building proxy for " ^ s_type_path path);
	let file, decls = (try
		TypeloadParse.parse_module ctx path p
	with
		| Not_found -> ctx.com.package_rules <- rules; typing_error ("Could not load proxy module " ^ s_type_path path ^ (if fst path = [] then " (try using absolute path)" else "")) p
		| e -> ctx.com.package_rules <- rules; raise e) in
	ctx.com.package_rules <- rules;
	let base_fields = [
		{ cff_name = "__cnx",null_pos; cff_pos = p; cff_doc = None; cff_meta = []; cff_access = []; cff_kind = FVar (Some (CTPath (mk_type_path (["haxe";"remoting"],if async then "AsyncConnection" else "Connection")),null_pos),None) };
		{ cff_name = "new",null_pos; cff_pos = p; cff_doc = None; cff_meta = []; cff_access = [APublic,null_pos]; cff_kind = FFun { f_args = [("c",null_pos),false,[],None,None]; f_type = None; f_expr = Some (EBinop (OpAssign,(EConst (Ident "__cnx"),p),(EConst (Ident "c"),p)),p); f_params = [] } };
	] in
	let tvoid = CTPath (mk_type_path ([],"Void")) in
	let build_field is_public acc f =
		if fst f.cff_name = "new" then
			acc
		else match f.cff_kind with
		| FFun fd when (is_public || List.mem_assoc APublic f.cff_access) && not (List.mem_assoc AStatic f.cff_access) ->
			if List.exists (fun (_,_,_,t,_) -> t = None) fd.f_args then typing_error ("Field " ^ fst f.cff_name ^ " type is not complete and cannot be used by RemotingProxy") p;
			let eargs = [EArrayDecl (List.map (fun ((a,_),_,_,_,_) -> (EConst (Ident a),p)) fd.f_args),p] in
			let ftype = (match fd.f_type with Some (CTPath { tpackage = []; tname = "Void" },_) -> None | _ -> fd.f_type) in
			let fargs, eargs = if async then match ftype with
				| Some (tret,_) -> fd.f_args @ [("__callb",null_pos),true,[],Some (CTFunction ([tret,null_pos],(tvoid,null_pos)),null_pos),None], eargs @ [EConst (Ident "__callb"),p]
				| _ -> fd.f_args, eargs @ [EConst (Ident "null"),p]
			else
				fd.f_args, eargs
			in
			let id = (EConst (String (fst f.cff_name,SDoubleQuotes)), p) in
			let id = if prot then id else ECall ((EConst (Ident "__unprotect__"),p),[id]),p in
			let expr = ECall (
				(efield (
					(ECall ((efield ((EConst (Ident "__cnx"),p),"resolve"),p),[id]),p),
					"call")
				,p),eargs),p
			in
			let expr = if async || ftype = None then expr else (EReturn (Some expr),p) in
			let fd = {
				f_params = fd.f_params;
				f_args = fargs;
				f_type = if async then None else ftype;
				f_expr = Some (EBlock [expr],p);
			} in
			{ cff_name = f.cff_name; cff_pos = f.cff_pos; cff_doc = None; cff_meta = []; cff_access = [APublic,null_pos]; cff_kind = FFun fd } :: acc
		| _ -> acc
	in
	let decls = List.map (fun d ->
		match d with
		| EClass c, p when fst c.d_name = t.tname ->
			let is_public = List.mem HExtern c.d_flags || List.mem HInterface c.d_flags in
			let fields = List.rev (List.fold_left (build_field is_public) base_fields c.d_data) in
			(EClass { c with d_flags = []; d_name = new_name,pos c.d_name; d_data = fields },p)
		| _ -> d
	) decls in
	let m = type_module ctx (t.tpackage,new_name) file decls p in
	add_dependency ctx.m.curmod m;
	try
		List.find (fun tdecl -> snd (t_path tdecl) = new_name) m.m_types
	with Not_found ->
		typing_error ("Module " ^ s_type_path path ^ " does not define type " ^ t.tname) p
	) in
	match t with
	| TClassDecl c2 when c2.cl_params = [] -> ignore(c2.cl_build()); c.cl_super <- Some (c2,[]);
	| _ -> typing_error "Remoting proxy must be a class without parameters" p

let on_inherit ctx c p (is_extends,tp) =
	if not is_extends then
		true
	else match fst tp with
	| { tpackage = ["haxe";"remoting"]; tname = "Proxy"; tparams = [TPType(CTPath t,null_pos)] } ->
		extend_remoting ctx c t p false true;
		false
	| { tpackage = ["haxe";"remoting"]; tname = "AsyncProxy"; tparams = [TPType(CTPath t,null_pos)] } ->
		extend_remoting ctx c t p true true;
		false
	| _ ->
		true
