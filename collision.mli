type t

(* Creates an empty map. *)
val create : unit -> t

(* Finds an unoccupied point in map [t] of size [(w, h)]. *)
val free : t -> Type.pos -> Type.pos

(* [test t e] returns a list of collisions that would be introduced by adding
 * [e] to the map.
 *
 * Does NOT modify [t].
 *)
val test : t -> Type.entity -> (Type.entity * Type.entity) list
    
(* Updates an entity's radius and position in map [t].
 *
 * If entity does not exist, update will create it.
 *)
val update : t -> Type.entity -> unit

(* Removes an entity from the map [t]. *)
val remove : t -> Type.entity -> unit

(* Returns a list of all collisions in map [t]. *)
val all : t -> (Type.entity * Type.entity) list
