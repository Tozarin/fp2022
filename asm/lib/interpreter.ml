(** Copyright 2021-2022, Startsev Matvey *)

(** SPDX-License-Identifier: LGPL-3.0-or-later *)

open Ast
open Int64

module type MONAD = sig
  type 'a t

  val return : 'a -> 'a t
  val ( >>= ) : 'a t -> ('a -> 'b t) -> 'b t
  val ( >> ) : 'a t -> 'b t -> 'b t
end

module type MONADERROR = sig
  include MONAD

  val error : string -> 'a t
end

module Result = struct
  type 'a t = ('a, string) Result.t

  let ( >>= ) = Result.bind
  let ( >> ) x f = x >>= fun _ -> f
  let return = Result.ok
  let error = Result.error
end

module Interpret (M : MONADERROR) = struct
  open M

  module MapVar = struct
    include Map.Make (String)

    let pp pp_v ppf m =
      Format.fprintf ppf "@[[@[";
      iter (fun k v -> Format.fprintf ppf "@[\"%s\": %a@],@\n" k pp_v v) m;
      Format.fprintf ppf "@]]@]"
  end

  (** global constans *)
  type var =
    | Flag of bool  (** EFLAGS *)
    | Reg64 of int64  (** not so large registers *)
    | Reg128 of int64 * int64  (** large registers *)
    | Const of int64 list  (** global consts *)
  [@@deriving show { with_path = false }]

  type envr = var MapVar.t [@@deriving show { with_path = false }]

  (** start values of registers *)
  let r_list =
    [
      ("ZF", Flag false);
      ("SF", Flag false);
      ("OF", Flag false);
      ("RAX", Reg64 0L);
      ("RBX", Reg64 0L);
      ("RCX", Reg64 0L);
      ("RDX", Reg64 0L);
      ("RSP", Reg64 0L);
      ("RBP", Reg64 0L);
      ("RSI", Reg64 0L);
      ("RDI", Reg64 0L);
      ("XMM0", Reg128 (0L, 0L));
      ("XMM1", Reg128 (0L, 0L));
      ("XMM2", Reg128 (0L, 0L));
      ("XMM3", Reg128 (0L, 0L));
      ("XMM4", Reg128 (0L, 0L));
      ("XMM5", Reg128 (0L, 0L));
      ("XMM6", Reg128 (0L, 0L));
      ("XMM7", Reg128 (0L, 0L));
    ]

  let is_jmp = function
    | "JMP" | "JE" | "JNE" | "JZ" | "JG" | "JGE" | "JL" | "JLE" -> true
    | _ -> false

  (** insert elements from list to map *)
  let prep = function [] -> MapVar.empty | l -> MapVar.of_seq (List.to_seq l)

  let full_name : type a. a reg -> string t = function
    | Reg8 x -> return (Printf.sprintf "R%cX" x.[0])
    | Reg16 x -> return (Printf.sprintf "R%s" x)
    | Reg32 x -> return (Printf.sprintf "R%c%c" x.[1] x.[2])
    | Reg64 x -> return x
  (* | Reg128 x -> return x *)

  let rreg = function "AH" | "BH" | "CH" | "DH" -> true | _ -> false

  let find_r64 : type a. var MapVar.t -> a reg -> Int64.t M.t =
   fun env reg ->
    full_name reg >>= fun name ->
    return (MapVar.find name env) >>= function
    | Reg64 x -> (
        match reg with
        | Reg8 name ->
            return
            @@
            if rreg name then rem x 0x1FFL else shift_right (rem x 0x1FFFFL) 8
        | Reg16 _ -> return @@ rem x 0x1FFFFL
        | Reg32 _ -> return @@ rem x 0x1FFFFFFFFL
        | Reg64 _ -> return x (* | _ -> error "Isnt reg64 or less" *))
    | _ -> error "Isnt reg64 or less"

  let find_r128 : var MapVar.t -> asmreg128 reg_e -> Int64.t list M.t =
   fun env reg ->
    let f num =
      let rec helper n ac =
        match ac with
        | 8 -> []
        | x -> helper (shift_right n 8) (x + 1) @ [ logand n 0xFFL ]
      in
      helper num 0
    in
    let name : asmreg128 reg_e -> string t = function
      | Reg128 x -> return x
      | _ -> error "Isnt reg128"
    in
    name reg >>= fun name ->
    return (MapVar.find name env) >>= function
    | Reg128 (x, y) -> return @@ f x @ f y
    | _ -> error "Isnt reg128"

  let find_v env name =
    return (MapVar.find name env) >>= function
    | Const x ->
        return @@ List.fold_left (fun x y -> add (shift_left x 8) y) 0L x
    | _ -> error "Isnt const"

  let find_f env f =
    return (MapVar.find f env) >>= function
    | Flag x -> return x
    | _ -> error "Isnt flag"

  let change_flag env name f = return @@ MapVar.add name (Flag f) env

  let change_eflag env x y z =
    change_flag env "ZF" x >>= fun env ->
    change_flag env "SF" y >>= fun env -> change_flag env "OF" z

  let change_reg64 :
      type a. var MapVar.t -> Int64.t -> a reg -> var MapVar.t M.t =
    let mask x y l r =
      let y =
        logand y (of_string @@ Printf.sprintf "0b0%s" (String.make (l - r) '1'))
      in
      let y = shift_left y r in
      let z =
        logand (shift_right x r)
          (of_string @@ Printf.sprintf "0b0%s" (String.make (l - r) '1'))
      in
      let x = sub x (shift_left z r) in
      add x y
    in
    let f env reg v l r =
      full_name reg >>= fun name ->
      find_r64 env reg >>= fun ov ->
      return @@ mask ov v l r >>= fun v ->
      return @@ MapVar.add name (Reg64 v) env
    in
    fun env v -> function
      | Reg8 x -> if rreg x then f env (Reg8 x) v 8 0 else f env (Reg8 x) v 16 8
      | Reg16 x -> f env (Reg16 x) v 16 0
      | Reg32 x -> f env (Reg32 x) v 32 0
      | Reg64 x -> f env (Reg64 x) v 64 0

  let change_reg128 :
      var MapVar.t -> Int64.t list -> asmreg128 reg_e -> var MapVar.t M.t =
    let split list p =
      let rec helper acc n xs =
        match (n, xs) with
        | 0, xs -> (acc, xs)
        | _, [] -> (acc, [])
        | n, x :: xs -> helper (x :: acc) (n - 1) xs
      in
      helper [] p list
    in
    let f l = List.fold_left (fun x y -> add (shift_left x 8) y) 0L l in
    fun env l -> function
      | Reg128 name ->
          let l = List.map (logand 0xFFL) l in
          let l1, l2 = split l 7 in
          let x, y = (f l1, f l2) in
          return @@ MapVar.add name (Reg128 (x, y)) env
      | _ -> error "Isnt reg128"

  let rec ev : var MapVar.t -> expr -> Int64.t M.t =
   fun env -> function
    | Add (l, r) ->
        ev env l >>= fun l ->
        ev env r >>= fun r -> return (add l r)
    | Sub (l, r) ->
        ev env l >>= fun l ->
        ev env r >>= fun r -> return (sub l r)
    | Mul (l, r) ->
        ev env l >>= fun l ->
        ev env r >>= fun r -> return (mul l r)
    | Div (l, r) ->
        ev env r >>= fun r ->
        if r = 0L then error "Division by zero"
        else ev env l >>= fun l -> return (div l r)
    | Const (ASMConst x) -> return @@ of_string x
    | Var (ASMVar x) -> find_v env x

  let rec inter env code s cmds =
    let tl = List.tl cmds in
    let rec assoc l = function
      | [] -> error "No such label"
      | Id label :: tl when label = l -> return tl
      | _ :: tl -> assoc l tl
    in
    let f x af =
      find_r64 env x >>= fun v ->
      let nv = af v 1L in
      change_reg64 env nv x >>= fun env ->
      find_r64 env x >>= fun nnv ->
      change_eflag env (nv = 0L) (nv < 0L) (nv <> nnv) >>= fun env ->
      return (env, s, tl)
    in
    let c_flags env =
      find_f env "ZF" >>= fun z ->
      find_f env "SF" >>= fun s ->
      find_f env "OF" >>= fun f -> return (z, s = f)
    in
    let jmp l conde =
      c_flags env >>= fun (f, ff) ->
      if conde (f, ff) then assoc l code >>= fun tl -> return (env, s, tl)
      else return (env, s, tl)
    in
    let to_r64 : type a. a reg_e -> dyn_reg t = function
      | Reg64 x -> return @@ Dyn (Reg64 x)
      | Reg32 x -> return @@ Dyn (Reg32 x)
      | Reg16 x -> return @@ Dyn (Reg16 x)
      | Reg8 x -> return @@ Dyn (Reg8 x)
      | Reg128 _ -> error "Isnt reg64 or less"
    in
    let ff x af =
      match x with
      | RegToReg (x, y) -> (
          match x with
          | Reg128 _ ->
              find_r128 env x >>= fun l1 ->
              find_r128 env y >>= fun l2 ->
              let nv = List.map2 af l1 l2 in
              change_reg128 env nv x >>= fun env -> return (env, s, tl)
          | _ ->
              to_r64 x >>= fun (Dyn x) ->
              to_r64 y >>= fun (Dyn y) ->
              find_r64 env x >>= fun ov ->
              find_r64 env y >>= fun y ->
              let nv = af ov y in
              change_reg64 env nv x >>= fun env ->
              find_r64 env x >>= fun nnv ->
              change_eflag env (nv = 0L) (nv < 0L) (nv <> nnv) >>= fun env ->
              return (env, s, tl))
      | RegToExpr (x, y) ->
          find_r64 env x >>= fun ov ->
          ev env y >>= fun y ->
          let nv = af ov y in
          change_reg64 env y x >>= fun env ->
          find_r64 env x >>= fun nnv ->
          change_eflag env (nv = 0L) (nv < 0L) (nv <> nnv) >>= fun env ->
          return (env, s, tl)
      | RegToVar (x, ASMVar y) ->
          find_r128 env x >>= fun l1 ->
          (match MapVar.find y env with
          | Const x -> return x
          | _ -> error "Isnt const")
          >>= fun l2 ->
          let l2 = List.init (16 - List.length l2) (fun _ -> 0L) @ l2 in
          let nv = List.map2 af l1 l2 in
          change_reg128 env nv x >>= fun env -> return (env, s, tl)
    in
    let sh64 x y af =
      to_r64 x >>= fun (Dyn x) ->
      find_r64 env x >>= fun ov ->
      let nv = af ov y in
      change_reg64 env nv x >>= fun env -> return (env, s, tl)
    in
    let to_l num =
      let rec helper n ac =
        match ac with
        | 8 -> []
        | x -> helper (shift_right n 8) (x + 1) @ [ logand n 0xFFL ]
      in
      helper num 0
    in
    match cmds with
    | Id _ :: _ -> return (env, s, tl)
    | Command x :: _ -> (
        match x with
        | RET -> return (env, s, [])
        | SYSCALL -> return (env, s, tl)
        | PUSH x -> find_r64 env x >>= fun v -> return (env, v :: s, tl)
        | POP x ->
            change_reg64 env (List.hd s) x >>= fun env ->
            return (env, List.tl s, tl)
        | INC x -> f x add
        | DEC x -> f x sub
        | NOT x -> f x (fun x _ -> lognot x)
        | NEG x -> f x (fun x _ -> neg x)
        | JMP x -> jmp x (fun _ -> true)
        | JE x | JZ x -> jmp x (fun (x, _) -> x)
        | JNE x -> jmp x (fun (x, _) -> not x)
        | JG x -> jmp x (fun (x, y) -> (not x) & y)
        | JGE x -> jmp x (fun (_, y) -> y)
        | JL x -> jmp x (fun (_, y) -> not y)
        | JLE x -> jmp x (fun (x, y) -> x & not y)
        | MOV x -> ff x (fun _ y -> y)
        | ADD x -> ff x add
        | SUB x -> ff x (fun x y -> sub y x)
        | IMUL x -> ff x mul
        | AND x -> ff x logand
        | OR x -> ff x logor
        | XOR x -> ff x logxor
        | SHL (x, y) -> (
            ev env y >>= fun y ->
            let y = to_int y in
            match x with
            | Reg128 name -> (
                return @@ MapVar.find name env >>= function
                | Reg128 (l1, l2) ->
                    let ny = shift_left l2 y in
                    let r = div l2 (shift_left 2L y) in
                    let nx = add (shift_left l1 y) r in
                    let nv = to_l nx @ to_l ny in
                    change_reg128 env nv x >>= fun env -> return (env, s, tl)
                | _ -> error "Isnt reg128")
            | _ -> sh64 x y shift_left)
        | SHR (x, y) -> (
            ev env y >>= fun y ->
            let y = to_int y in
            match x with
            | Reg128 name -> (
                return @@ MapVar.find name env >>= function
                | Reg128 (l1, l2) ->
                    let nx = shift_right l1 y in
                    let r = rem l1 (shift_left 2L y) in
                    let ny = add (shift_right l2 y) (shift_left r (64 - y)) in
                    let nv = to_l nx @ to_l ny in
                    change_reg128 env nv x >>= fun env -> return (env, s, tl)
                | _ -> error "Isnt reg128")
            | _ -> sh64 x y shift_right)
        | CMP x ->
            let cenv = env in
            inter cenv code s (Command (SUB x) :: tl) >>= fun (cenv, _, _) ->
            find_f cenv "ZF" >>= fun zf ->
            change_flag env "ZF" zf >>= fun env -> return (env, s, tl))
    | _ -> return (env, s, [])

  let rec code_sec_inter env s code = function
    | cmd :: tl ->
        inter env code s (cmd :: tl) >>= fun (env, s, c) ->
        code_sec_inter env s code c
    | [] -> return (env, s, [])

  let rec data_sec_inter env s vars =
    let mask v l r =
      let ones l r =
        of_string
        @@ Printf.sprintf "0b0%s%s"
             (String.make (l - r) '1')
             (String.make r '0')
      in
      logand v (ones l r)
    in
    let cut b = function
      | Num x ->
          let n = List.map (fun x -> mask (of_string x) b 0) x in
          n
      | Str s ->
          let explode s = List.init (String.length s) (String.get s) in
          List.map (fun x -> of_int @@ Char.code x) (explode s)
    in
    match vars with
    | Variable (name, t, v) :: tl ->
        let vv =
          match t with
          | DB -> cut 8 v
          | DW -> cut 16 v
          | DD -> cut 32 v
          | DQ -> cut 64 v
          | DT -> cut 80 v
        in
        let vv = Const vv in
        let env = MapVar.add name vv env in
        data_sec_inter env s tl
    | [] -> return (env, s, [])

  let rec interpret env s = function
    | h :: tl -> (
        match h with
        | Code code ->
            code_sec_inter env s code code >>= fun (env, s, _) ->
            interpret env s tl
        | Data data ->
            data_sec_inter env s data >>= fun (env, s, _) -> interpret env s tl)
    | [] -> return (env, s, [])
end
