open Sparql ;;
open Reorder ;;

type algebra =
  | Readfile3 of string
  | Readfile2 of string
  | Filter of string * string * algebra
  | Keep of string list * algebra
  | Join of algebra * algebra
  | Union of algebra * algebra
  | LeftJoin of algebra * algebra
  | Rename of string * string * algebra
  | Distinct of algebra
  | Order of (string*bool) list*algebra
                                  
let rec print_algebra term = 
  
  let gid = 
    let id = ref 0 in
    fun () -> incr id ; string_of_int (!id) 
  in
  
  let lines = ref [] in
  
  let add l = lines := ("    "^l^"\n")::(!lines) in 

  let () = add "def readpred (s:String) = " ;
           add "  if(org.apache.hadoop.fs.FileSystem.get(sc.hadoopConfiguration).exists(new org.apache.hadoop.fs.Path(\"DATAHDFSPATH\"+s)))" ;
           add "    {sc.textFile(\"DATAHDFSPATH\"+s).map{line => val field:Array[String]=line.split(\" \",2); (field(0),field(1))}}" ;
           add "  else" ;
           add "    {sc.emptyRDD[(String,String)]};" in

  let escape_var a =
    if a.[0] = '?'
    then let b = Bytes.copy a in (Bytes.set b 0 'v' ; b)
    else
      if a.[0] = '$'
      then let b = Bytes.copy a in (Bytes.set b 0 'd' ; b)
      else a
  in

  let rec join = function
    | [] -> ""
    | [a] -> escape_var a
    | a::q -> escape_var a^","^join q
  in

  let renamedup l1 l2 =
    (* bis_varname is not a possible variable name *)
    List.map (fun t -> if List.mem t l2 then "bis_"^(escape_var t) else t) l1
  in

  (* Numero hashes predicate names; in Vertical partionning the
  (subject,object) associated with pred are stored in (numero
  pred)^".pred "*)
  let numero(s:string):string=
    let sum = ref 0 in
    String.iter (fun c -> sum:=Char.code(c)+ (!sum)) s ;
    string_of_int (!sum)
  in
  
  (*foo term returns (id,cols) where "V"id is the variable associated
  with term and cols is the list of columns of term (in the order they
  appear in the bdd *)

  let trad_one = Hashtbl.create 17 in

  let normalize_var_name code =
    let rename =
      let a = ref [] in
      let cur = ref 0 in
      fun s ->
      try
        List.assoc s (!a)
      with
        Not_found ->
        let trad=string_of_int (!cur) in
        a:= (s,trad)::!a ;
        incr cur ;
        trad
    in
    let rec foo = function
      | Filter(s,v,c) -> Filter(rename s, v,foo c)
      | Keep(l,c) -> Keep (List.map rename l,foo c)
      | Join(a,b) -> Join(foo a, foo b)
      | Union(a,b) -> Union(foo a, foo b)
      | LeftJoin(a,b) -> LeftJoin(foo a, foo b)
      | Rename(o,n,c) -> Rename(rename o, rename n,foo c)
      | Distinct c -> Distinct (foo c)
      | Order(l,c) -> Order(List.map (fun (x,b) -> rename x,b) l,foo c)
      | v -> v
    in
    foo code
  in

  let rec cols = function
    | Readfile3(f) -> ["s";"p";"o"]
    | Readfile2(f) -> ["s";"o"]
                    
    | Distinct c
    | Order(_,c)
      | Filter(_,_,c) -> cols c
                       
    | Keep(k,c) -> k
                 
    | Union(a,b) 
      | LeftJoin(a,b)
      | Join(a,b) ->
       let c_a = cols a in
       c_a @ (List.filter (fun x -> not (List.mem x c_a)) (cols b))
       
    | Rename(o,n,c) -> List.map (fun x -> if x=o then n else x) (cols c)
  in
       
  let rec foo l =
    let normalized = normalize_var_name l in
    try
      let calc=Hashtbl.find trad_one normalized in
      calc,cols l
    with
      Not_found ->        
        let res = "v"^gid () in 
        let code,cols = match l with 
          | Readfile3(f) ->
             "val "^res^"=sc.textFile(\""^f^"\").map{line => val field:Array[String]=line.split(\" \",3); (field(0),field(1),field(2).substring(0,field(2).lastIndexOf(\" \")))};",["s";"p";"o"]
          | Readfile2(f) ->
             "val "^res^"=readpred(\""^(numero f)^".pred\") //"^f,["s";"o"]
               
          | Filter(c,v,a) ->
             let code,cols = foo a in
             "val "^res^"="^code^".filter{case ("^(join cols)^") => "^(escape_var c)^".equals("^(escape_var v)^")}",cols
                                                                                                                  
          | Keep (keepcols,a) ->
             let code,cols = foo a in
             "val "^res^"="^code^
             (if cols <> keepcols
             then
               ".map{case ("^(join cols)^") => ("^(join keepcols)^")}"
             else
               " // useless keepcols"),keepcols
               
          | LeftJoin(a,b) ->
             let code_a,cols_a = foo a
             and code_b,cols_b = foo b in
             let cols_join = List.filter (fun x -> List.mem x cols_b) cols_a in
             let cols_of_b = List.filter (fun x -> not (List.mem x cols_join)) cols_b in
             let cols_union_some = cols_a@(cols_of_b) in
             let cols_union_none = cols_a@(List.map (fun x -> "\"\"") cols_of_b) in
             let cols_b_bis = renamedup cols_b cols_a in
             (if cols_join = []
              then
                 "val "^res^"="^code_a^".cartesian("^code_b^")"
              else
                 "val "^res^"="^code_a^".keyBy{case ("^(join cols_a)^") => ("^(join cols_join)
                 ^")}.leftOuterJoin("^code_b^".keyBy{case ("^(join cols_b)^")=>("^(join cols_join)^")}).values")
             ^".map{case( ("^(join cols_a)^"), opt_b)=> opt_b match { case None => ("^(join cols_union_none)^") case Some( ("^join cols_b_bis^") ) => ("^join cols_union_some ^") }}",cols_union_some
               
          | Join(a,b) ->
             let code_a,cols_a = foo a
             and code_b,cols_b = foo b in
             let cols_join = List.filter (fun x -> List.mem x cols_b) cols_a in
             let cols_union = cols_a@(List.filter (fun x -> not (List.mem x cols_join)) cols_b) in
             let cols_b_bis = renamedup cols_b cols_a in
             (if cols_join = []
              then
                 "val "^res^"="^code_a^".cartesian("^code_b^")"
              else
                 "val "^res^"="^code_a^".keyBy{case ("^(join cols_a)^") => ("^(join cols_join)
                 ^")}.join("^code_b^".keyBy{case ("^(join cols_b)^")=>("^(join cols_join)^")}).values")
             ^".map{case( ("^(join cols_a)^"),("^(join cols_b_bis)^"))=>("^(join cols_union)^")}",cols_union
               
          | Rename(o,n,c) ->
             let code_c,cols_c = foo c in
             "val "^res^"="^code_c,(List.map (fun x -> if x=o then n else x) cols_c)

          | Union (a,b) ->
             let code_a,cols_a = foo a
             and code_b,cols_b = foo b in
             let cols_union = cols_a@(List.filter (fun x -> not (List.mem x cols_a)) cols_b) in
             let new_cols_a = List.map (fun x -> if List.mem x cols_a then x else "\"\"") cols_union in
             let new_cols_b = List.map (fun x -> if List.mem x cols_b then x else "\"\"") cols_union in
             "val "^res^"= ("^code_a^".map{case ("^(join cols_a)^")=>("^(join new_cols_a)^")}).union("^code_b^".map{case("^(join cols_b)^") => ("^(join new_cols_b)^")})",cols_union
          | Distinct(a) ->
             let code_a,cols_a = foo a in
             "val "^res^" ="^code_a^".distinct() ",cols_a
          | Order(l,a) ->
             let code_a,cols_a = foo a in
             let cols_sort = List.filter (fun x -> List.mem_assoc x l) cols_a in
             let type_sort = "("^join (List.map (fun s -> "String") cols_sort)^")" in
             let rec foo x = function
               | [] -> failwith "sort column not present!"
               | a::q -> if x=a then 1 else (1+foo x q)
             in
             let ith = List.map (fun (v,s) -> string_of_int (foo v cols_a),s) l in
             match cols_sort
             with
             | [] -> "val "^res^"="^code_a,cols_a
             | [col_sort] ->
                let side = List.assoc col_sort l in 
                "val "^res^"="^code_a^".keyBy{case ("^join cols_a^")=>"^(escape_var col_sort)^"}.sortByKey("^string_of_bool side^").values",cols_a
             | cols_sort ->
                begin
                  add ("implicit val specifiedOrdering = new Ordering["^type_sort^"] {") ;
                  add ("       override def compare(a: "^type_sort^", b: "^type_sort^") = " );
                  List.iter (fun (v,s) -> let side = if s then "" else "(-1)*" in
                                          add ("if ( a._"^v^" != b._"^v^" ) { "^side^"(a._"^v^".compare(b._"^v^")) } else ")) ith ;
                  add " { 0 } }" ;
                  "val "^res^" ="^code_a^".keyBy{case ("^join cols_a^")=>("^join cols_sort
                  ^")}.sortByKey(true).values ",cols_a
                end
        in
        add code ;
        Hashtbl.add trad_one normalized res ; res,cols
  in
  let code,cols = foo term in
  add ("val Qfinal="^code^".collect") ;
  (* add ("//// order is "^(join cols)) ; *)
  List.iter print_string (List.rev (!lines)) 
;;
  
let print_query distinguished modifiers optim stmt =
  let print_list_tp l =
    let rec foo = function
      | [] -> failwith "Empty list of TP"
      | [a] -> print_tp a
      | a::q -> print_tp a ; foo q
    in
    match optim with
    | 0 -> foo (List.rev l)
    | 1 -> foo (Reorder.no_cartesian l)
    | 2 -> foo (Reorder.reorder l)
    | _ -> foo (Reorder.no_cartesian l)
  in

  let print_opt  = function
    | (a,[]) -> print_list_tp a
    | (a,b) -> print_list_tp a ; print_list_tp b
  in

  let rec print_toplevel = function
    | [] -> failwith "Empty query!"
    | [a] -> print_opt a
    | a::q -> print_opt a ; print_string "UNION {" ; print_toplevel q ; print_string " }"
  in

  let rec print_list_order = function
    | [] -> print_string ""
    | (x,true)::q -> print_string x ; print_list_order q
    | _::q -> print_list_order q
  in

  let rec print_modifiers bgp = function
    | [] -> 
       begin
        List.iter (Printf.printf "%s ") distinguished ;
        print_string "\nWHERE {\n" ;
        print_toplevel stmt ;
        print_string "}\n" ;
       end
    | OrderBy(l)::q ->
       begin
        print_modifiers bgp q ;
	print_string "Order By { " ;
        print_list_order l ;
	print_string " }" ;
       end
    | Distinct::q ->
       begin 
        print_string "DISTINCT " ; 
	print_modifiers bgp q ;
       end
  in
  
  print_string "SELECT ";
  print_modifiers stmt modifiers ;

;;

let translate distinguished modifiers vertical optim stmt =
  
  let translate_el (base,cols) = function
    | Exact(v),name -> (Filter(name,"\""^v^"\"",base),cols)
    | Variable(v),name ->
       if List.mem v cols
       then Filter(name,v,base),cols
       else (Rename(name,v,base),v::cols)
  in

  let translate_tp = function
    | s,Exact(p),o when vertical -> Keep(list_var [s;o],fst (List.fold_left translate_el (Readfile2(p),[]) [s,"s";o,"o"]))
    | s,p,o -> Keep(list_var [s;p;o],fst (List.fold_left translate_el (Readfile3("all"),[]) [s,"s";p,"p";o,"o"]))
  in

  let translate_list_tp l =
    let rec foo = function
      | [] -> failwith "Empty list of TP"
      | [a] -> translate_tp a
      | a::q -> Join(translate_tp a,foo q)
    in
    match optim with
    | 0 -> foo (List.rev l)
    | 1 -> foo (Reorder.no_cartesian l)
    | 2 -> foo (Reorder.reorder l)
    | _ -> foo (Reorder.no_cartesian l)
  in

  let translate_opt  = function
    | (a,[]) -> translate_list_tp a
    | (a,b) -> LeftJoin(translate_list_tp a,translate_list_tp b)
  in

  let rec translate_toplevel = function
    | [] -> failwith "Empty query!"
    | [a] -> translate_opt a
    | a::q -> Union(translate_opt a,translate_toplevel q)
  in

  let rec add_modifiers t = function
    | [] -> t
    | OrderBy(l)::q -> Order(l,add_modifiers t q)
    | Distinct::q -> Distinct(add_modifiers t q)
  in
  
  add_modifiers (match distinguished with
   | ["*"] -> translate_toplevel stmt
   | _ ->  Keep(distinguished,  translate_toplevel stmt))
   modifiers 
  
  (* let _ = *)
(*    print_algebra (Union(Join ( *)
(*                      Keep(["pers"],Rename("s","pers",Filter("o","21",Readfile2("age")))), *)
(*                      Keep(["gender";"pers"],Rename("o","gender",Rename("s","pers",Readfile2("gender")))) *)
(*                       ), *)
(*                       Keep(["a"],Rename("s","a",Readfile2("age") )) *)
(*                       )) *)
  
