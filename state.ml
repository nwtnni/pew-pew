open Stype
open Settings

module H = Hashtbl
module C = Collision

type t = {
  mutable s_rad : rad;
  mutable time  : int;
  lock          : Mutex.t;
  size          : pos;
  s_id          : id;
  s_name        : name;
  gen           : Generate.t;
  map           : C.t;
  ammo          : (id, ammo)   H.t;
  bullets       : (id, bullet) H.t;
  rocks         : (id, rock)   H.t;
  guns          : (id, gun)    H.t;
  players       : (id, player) H.t;
}

(* --------------------------------- *)
(*                                   *)
(*         Utility Functions         *)
(*                                   *)
(* --------------------------------- *)

let to_values h =
  let f' id e acc = e :: acc in
  H.fold f' h []

let iter_hash f h = to_values h |> List.iter f
let map_hash f h = to_values h |> List.map f
let filter_hash f h = to_values h |> List.filter f

let sqdist (x1, y1) (x2, y2) =
  let x = x2 -. x1 in
  let y = y2 -. y1 in
  (x*.x) +. (y*.y)

let inside c r p = r*.r > sqdist c p

let get_lock st = st.lock

(* --------------------------------- *)
(*                                   *)
(*          Type Conversions         *)
(*                                   *)
(* --------------------------------- *)

(* [near s p to_pos h to_json] is a JSON list of
 * elements in Hashtbl [h] in state [s], which are
 * converted by function [to_pos] into positions,
 * to be filtered by distance from player [p] and
 * converted into JSON by function to_json.
 *)
let near s p to_pos h to_json = h
  |> filter_hash (fun x -> inside p.p_pos vision_radius (to_pos x))
  |> List.map to_json

(* [near_guns s p] is a JSON list of guns that are
 * visible to the player (i.e. within vision_radius
 * or in someone's inventory).
 *)
let near_guns s p = s.guns
  |> filter_hash (fun g ->
      g.g_own <> no_owner ||
      inside p.p_pos vision_radius g.g_pos
    )
  |> List.map gun_to_json

let to_json_string s p_id =
  let x, y = s.size in
  let p = H.find s.players p_id in
  let a = near s p (fun a -> a.a_pos) s.ammo ammo_to_json in
  let b = near s p (fun b -> b.b_pos) s.bullets bullet_to_json in
  let r = near s p (fun r -> r.r_pos) s.rocks rock_to_json in
  let g = near_guns s p in
  let p = map_hash (fun p -> player_to_json p) s.players in
  Yojson.Basic.to_string (`Assoc [
    ("id"      , `Int s.s_id);
    ("name"    , `String s.s_name);
    ("size"    , `List [`Float x; `Float y]);
    ("rad"     , `Float s.s_rad);
    ("ammo"    , `List a);
    ("bullets" , `List b);
    ("guns"    , `List g);
    ("players" , `List p);
    ("rocks"   , `List r);
  ])

let to_description s =
  `Assoc [
      ("game_name"    , `String s.s_name);
      ("game_id"      , `Int    s.s_id);
      ("game_players" , `List (map_hash (fun p -> `String p.p_name) s.players))
  ]

let to_list s =
  let a  = map_hash ammo_to_entity s.ammo in
  let b  = filter_hash (fun b -> b.b_own = no_owner) s.bullets in
  let b' = List.map bullet_to_entity b in
  let r  = map_hash rock_to_entity s.rocks in
  let g  = map_hash gun_to_entity s.guns in
  let p  = map_hash player_to_entity s.players in
  a @ b' @ r @ g @ p

(* --------------------------------- *)
(*                                   *)
(*  Entity Creation and Destruction  *)
(*                                   *)
(* --------------------------------- *)

let rec repeat f n =
  if n <= 0 then ()
  else let _ = f () in repeat f (n - 1)

let free s = C.free s.map s.size

let create_ammo s () =
  let g = map_hash (fun g -> g.g_type) s.guns in
  let a = Generate.ammo s.gen (free s) g in
  let e = ammo_to_entity a in
  let _ = C.update s.map e in
  H.add s.ammo a.a_id a

let create_gun s () =
  let g = Generate.gun s.gen (free s) in
  let e = gun_to_entity g in
  let _ = C.update s.map e in
  H.add s.guns g.g_id g

let create_rock s () =
  let r = Generate.rock s.gen (free s) in
  let e = rock_to_entity r in
  let _ = C.update s.map e in
  H.add s.rocks r.r_id r

let create_player s id =
  let p = Generate.player s.gen (free s) id in
  let e = player_to_entity p in
  let _ = C.update s.map e in
  H.add s.players p.p_id p; p.p_id

let create game_id game_name player_name =
  let s = {
    s_id    = game_id;
    s_name  = game_name;
    s_rad   = ring_radius;
    size    = map_width, map_height;
    lock    = Mutex.create ();
    time    = 0;
    gen     = Generate.create ();
    map     = C.create ();
    ammo    = H.create 50;
    bullets = H.create 50;
    guns    = H.create 10;
    players = H.create 4;
    rocks   = H.create 50;
  } in
  repeat (create_rock s) initial_rocks;
  repeat (create_gun  s) initial_guns;
  repeat (create_ammo s) initial_ammo;
  let p_id = create_player s player_name in
  (s, p_id)

let destroy_bullet s b_id =
  let b = H.find s.bullets b_id in
  let _ = H.remove s.bullets b_id in
  let _ = C.remove s.map (bullet_to_entity b) in ()

let destroy_ammo s a_id =
  let a = H.find s.ammo    a_id in
  let _ = H.remove s.ammo  a_id in
  let _ = C.remove s.map (ammo_to_entity a) in ()

let destroy_gun s g_id =
  let g = H.find s.guns    g_id in
  let _ = H.remove s.guns  g_id in
  let _ = C.remove s.map (gun_to_entity g) in
  if g.g_own = no_owner then () else
  let p = H.find s.players g.g_own in
  let inv' = List.filter (fun id -> id <> g.g_id) p.p_inv in
  H.replace s.players p.p_id {p with p_inv = inv'}

let destroy_player s p_id =
  let p = H.find s.players p_id in
  let _ = H.remove s.players p_id in
  let _ = C.remove s.map (player_to_entity p) in
  let _ = List.iter (fun g_id -> H.remove s.guns g_id) p.p_inv in ()

(* --------------------------------- *)
(*                                   *)
(*        Collision Handling         *)
(*                                   *)
(* --------------------------------- *)

let has_type s inv t = List.find_opt (fun g_id -> let g = H.find s.guns g_id in g.g_type = t) inv

(* Player-ammo. If player owns the correct
 * gun type for the ammo drop, pick it up; otherwise collision. *)
let collision_pa s p_id a_id =
  let p = H.find s.players p_id in
  let a = H.find s.ammo    a_id in
  match has_type s p.p_inv a.a_type with
  | None    -> true
  | Some g_id  -> let g = H.find s.guns g_id in
    let g' = {g with g_ammo = g.g_ammo + a.a_amt} in
    let _  = H.replace  s.guns g'.g_id g' in
    let _  = H.remove   s.ammo a_id       in
    let _  = C.remove s.map (ammo_to_entity a) in false

(* Player-bullet. Player always takes damage, with friendly fire. *)
let collision_pb s p_id b_id =
  let p  = H.find s.players p_id in
  let b  = H.find s.bullets b_id in
  let hp' = p.p_hp - b.b_dmg in
  let p' = {p with p_hp = hp'} in
  let _  = H.replace  s.players p_id p' in
  let _  = H.remove   s.bullets b_id    in
  let _  = C.remove s.map (bullet_to_entity b) in
  let _  = if hp' <= 0 then C.remove s.map (player_to_entity p)
  else () in false

(* Player-gun. If player doesn't own this
 * type of gun, pick it up; otherwise collide. *)
let collision_pg s p_id g_id =
  let p = H.find s.players p_id in
  let g = H.find s.guns    g_id in
  match has_type s p.p_inv g.g_type with
  | Some _ -> true
  | None   ->
    let p' = {p with p_inv = g.g_id :: p.p_inv} in
    let _ = H.replace s.players p.p_id p' in
    let g' = {g with g_own = p_id} in
    let _  = H.replace s.guns g.g_id g' in
    C.remove s.map (gun_to_entity g); false

(* Imposes order on collision pairs for cleaner pattern matching. *)
let order e e' = match e, e' with
| Bullet _, Player _
| Ammo   _, Player _
| Gun    _, Player _
| Rock   _, Player _
| Ammo   _, Bullet _
| Gun    _, Bullet _
| Rock   _, Bullet _ -> (e', e)
| _, _ -> (e, e')

(* Main collision function.
 *
 * Returns true if movement was impeded (i.e. move was invalid)
 * and false otherwise.
 *)
let collision s (e, e') = match order e e' with
| Player (p_id, _, _), Ammo   (a_id, _, _)  -> collision_pa s p_id a_id
| Player (p_id, _, _), Bullet (b_id, _, _)  -> collision_pb s p_id b_id
| Player (p_id, _, _), Gun    (g_id, _, _)  -> collision_pg s p_id g_id
| Player (p_id, _, _), Rock   (r_id, _, _)  -> true
| Player (p_id, _, _), Player (p_id', _, _) -> true
| Bullet (b_id, _, _), Ammo   (a_id, _, _)  -> destroy_bullet s b_id; destroy_ammo s a_id; false
| Bullet (b_id, _, _), Bullet (b_id', _, _) -> destroy_bullet s b_id; destroy_bullet s b_id'; false
| Bullet (b_id, _, _), Gun    (g_id, _, _)  -> destroy_bullet s b_id; destroy_gun s g_id; false
| Bullet (b_id, _, _), Rock   (r_id, _, _)  -> destroy_bullet s b_id; false
| _, _ -> failwith "Error in map generation"

(* --------------------------------- *)
(*                                   *)
(*           World Stepping          *)
(*                                   *)
(* --------------------------------- *)

(* Stepping implementation must do the following:
 *
 *  1) Remove timed-out bullets
 *  2) Remove out-of-bounds and dead players
 *  3) Update bullet list and positions by stepping bullets
 *  4) Handle all collisions
 *  5) Update all gun cooldowns
 *  6) Increase time step and decrease radius
 *  7) Spawn new ammo
 *  8) Spawn new guns
 *)

let remove_old_bullets s = iter_hash (fun b ->
    if b.b_time > bullet_timeout then
      destroy_bullet s b.b_id else ()
  ) s.bullets

let remove_dead_players s = iter_hash (fun p ->
    let w, h = s.size in
    if p.p_hp <= 0 || not (inside (w/.2., h/.2.) s.s_rad p.p_pos) then
      destroy_player s p.p_id else ()
  ) s.players

let update_bullets s = iter_hash (fun b ->
    let b' = b.b_step b in
    H.replace s.bullets b.b_id b';
    C.update s.map (bullet_to_entity b')
  ) s.bullets

let handle_collisions s =
  let _ = List.map (collision s) (C.all s.map) in ()

let update_guns s = iter_hash (fun g ->
    H.replace s.guns g.g_id
      {g with g_cd = max 0 (g.g_cd - gun_cd_rate)}
  ) s.guns

let update_state s =
  s.time  <- s.time + 1;
  s.s_rad <- s.s_rad -. constrict_rate

let spawn_ammo s = if (s.time mod ammo_spawn_cd = 0) then
    repeat (create_ammo s) ammo_spawn_count
  else ()

let spawn_guns s = if (s.time mod gun_spawn_cd = 0) then
    repeat (create_gun s) gun_spawn_count
  else ()

let step s =
  remove_old_bullets s;
  remove_dead_players s;
  update_bullets s;
  handle_collisions s;
  update_guns s;
  update_state s;
  spawn_ammo s;
  spawn_guns s

(* --------------------------------- *)
(*                                   *)
(*        Player Interaction         *)
(*                                   *)
(* --------------------------------- *)

let fire s p_id g_id =
  let p = H.find s.players p_id in
  let g = H.find s.guns g_id in
  if p.p_hp <= 0 then destroy_player s p.p_id else
  if not (List.exists (fun id -> id = g_id) p.p_inv) then () else
    if not (g.g_own = p.p_id && g.g_cd = 0) then () else
      let _ = H.replace s.guns g_id {g with g_cd = g.g_rate} in
      let _ = H.replace s.players p.p_id {p with p_last = g.g_type} in
      let bullets = Generate.bullet s.gen p g in
  List.iter (fun b ->
      let _ = H.add s.bullets b.b_id b in
      C.update s.map (bullet_to_entity b)
    ) bullets

let move s p_id pos =
  let (x, y) = pos in
  if x < 0. || y < 0. || x > map_width || y > map_height then ()
  else
  let p = H.find s.players p_id in
  if p.p_hp <= 0 then destroy_player s p.p_id else
  let _ = C.remove s.map (player_to_entity p) in
  let p' = {p with p_pos = pos} in 
  let collided = player_to_entity p'
    |> C.test s.map
    |> List.map (collision s)
    |> List.exists (fun b -> b = true) in
  if collided then () else
  let _ = C.update s.map (player_to_entity p') in
  H.replace s.players p_id p'
