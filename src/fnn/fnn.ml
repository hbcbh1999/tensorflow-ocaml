open Core_kernel.Std

type _1d
type _2d
type _3d

module Shape = struct
  type 'a t =
    | D1 : int -> _1d t
    | D2 : int * int -> _2d t
    | D3 : int * int * int -> _3d t

  let dim_list (type a) (t : a t) =
    match t with
    | D1 d -> [ d ]
    | D2 (d, d') -> [ d; d' ]
    | D3 (d, d', d'') -> [ d; d'; d'' ]
end

exception Shape_mismatch of int list * int list * string
let () =
  Caml.Printexc.register_printer (function
    | Shape_mismatch (dims, dims', str) ->
      let dims = List.map dims ~f:Int.to_string |> String.concat ~sep:", " in
      let dims' = List.map dims' ~f:Int.to_string |> String.concat ~sep:", " in
      Some (sprintf "Shape mismatch %s: %s <> %s" str dims dims')
    | _ -> None)

let shape_mismatch shape1 shape2 ~op_name =
  let shape1 = Shape.dim_list shape1 in
  let shape2 = Shape.dim_list shape2 in
  raise (Shape_mismatch (shape1, shape2, op_name))

module Input = struct
  include Int

  let create =
    let cnt = ref 0 in
    fun () ->
      incr cnt;
      !cnt
end

module Unary = struct
  type t =
    | Sigmoid
    | Tanh
    | Relu
    | Softmax

  let apply t node =
    match t with
    | Sigmoid -> Ops.sigmoid node
    | Tanh    -> Ops.tanh node
    | Relu    -> Ops.relu node
    | Softmax -> Ops.softmax node
end

module Binary = struct
  type t =
    | Plus
    | Minus
    | Times

  let op_name = function
    | Plus  -> "plus"
    | Minus -> "minus"
    | Times -> "times"

  let apply t node1 node2 =
    match t with
    | Plus  -> Ops.(node1 + node2)
    | Minus -> Ops.(node1 - node2)
    | Times -> Ops.(node1 * node2)
end

type init = [ `const of float | `normal of float | `truncated_normal of float ]

type 'a op =
  | Input : Input.t -> 'a op
  | Const : float -> 'a op
  | Unary : Unary.t * 'a t -> 'a op
  | Binary : Binary.t * 'a t * 'a t -> 'a op
  | Dense : init * init * int * _1d t -> _1d op
and 'a t =
  { shape : 'a Shape.t
  ; op : 'a op
  }

type p = P : _ t -> p

let shape t = t.shape

let input ~shape =
  let input = Input.create () in
  { shape
  ; op = Input input
  }, input

let const f ~shape =
  { shape
  ; op = Const f
  }

let unary unary t =
  { shape = shape t
  ; op = Unary (unary, t)
  }

let sigmoid t = unary Sigmoid t
let tanh t = unary Tanh t
let relu t = unary Relu t
let softmax t = unary Softmax t

let binary binary t1 t2 =
  if t1.shape <> t2.shape
  then shape_mismatch t1.shape t2.shape ~op_name:(Binary.op_name binary);
  { shape = shape t1
  ; op = Binary (binary, t1, t2)
  }

let (+) t1 t2 = binary Plus t1 t2
let (-) t1 t2 = binary Minus t1 t2
let ( * ) t1 t2 = binary Times t1 t2

let dense ?(w_init = `const 0.) ?(b_init = `const 0.) dim =
  Staged.stage (fun t ->
    { shape = D1 dim
    ; op = Dense (w_init, b_init, dim, t)
    })

let build_node t ~type_ =
  let inputs = Input.Table.create () in
  let rec walk (P t) =
    match t.op with
    | Unary (unary, t) -> Unary.apply unary (walk (P t))
    | Binary (binary, t1, t2) -> Binary.apply binary (walk (P t1)) (walk (P t2))
    | Const f -> Ops.f_or_d ~shape:(Shape.dim_list t.shape) ~type_ f
    | Dense _ -> failwith "TODO"
    | Input input ->
      Hashtbl.find_or_add inputs input ~default:(fun () ->
        Ops.placeholder ~type_ (Shape.dim_list t.shape))
      |> Ops.Placeholder.to_node
  in
  walk t

module Model = struct
  type 'a fnn = 'a t

  type 'a t =
    { session : Session.t
    ; node : Node.p
    ; shape : 'a Shape.t
    }

  let create fnn type_ =
    let session = Session.create () in
    { session
    ; node = Node.P (build_node (P fnn) ~type_)
    ; shape = fnn.shape
    }
end
