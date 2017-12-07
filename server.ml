open Lwt
open Cohttp
open Cohttp_lwt_unix
open Yojson
open State

(* Each element in the lobby has type:
	 (
	 game_id <int>, 
	 state <state>
	 )
*)
let lobby = ref []

(* A counter of the number of games.
   Used to determine game_ids. *)
let game_count = ref 0

(* Yojson Utility Methods *)
let to_string = Yojson.Basic.Util.to_string
let to_list = Yojson.Basic.Util.to_list
let to_float = Yojson.Basic.Util.to_float
let member = Yojson.Basic.Util.member

(* Type of a request *)
type request = 
{
	body: string;
	params: (string * string) list
}

(* --------------------------------- *)
(*                                   *)
(*         Lobby API Callbacks       *)
(*                                   *)
(* --------------------------------- *)

(* TODO ASK FOR A GAME NAME FUNCTION IN STATE *)
(* TODO ASK FOR A LIST OF PLAYERS IN THE STATE *)

(* Converts an element in lobby to JSON. *)
(* let lobby_to_json (lid,lname,st) =
	`Assoc [
		("game_name", `String lname);
		("game_id"  , `Int    lid);
		("players"  , `List   (List.map (fun x -> `String x) (State.players st)))
	]

let get_lobbies _ = 
	let body = `List (List.map lobby_to_json lobby) in
	Server.respond_string ~status:`OK ~body () *)


let names_from_json req =
	let j = Yojson.Basic.from_string req.body in
	let g_name = j |> member "game_name" |> to_string in
	let p_name = j |> member "player_name" |> to_string in 
	(g_name, p_name)

let create_game req =
	let (g_name, p_name) = names_from_json req in
	let gid = !game_count in 
	let (st, pid) = create gid g_name p_name in
	let body = 
		`Assoc [
		   ("game_id",   `String gid); 
			 ("player_id", `Int pid)
		 ] in
	game_count := !game_count + 1;
	lobby := (gid, st) :: !lobby;
	Server.respond_string ~status:`Created ~body:"Created." ()

let rec add_player lob_lst gid p_name =
	match lob_lst with
	| [] 			 					 -> failwith "Cannot find lobby"
	| (gid',st)::t ->
		if gid' = gid 
		then create_player st p_name
		else add_player t gid p_name  

let join_game req =
	let gid = List.assoc "game_id" req.params |> int_of_string in
	let p_name = List.assoc "player_name" req.params in
	let body = add_player !lobby gid p_name in
	Server.respond_string ~status:`Created ~body ()


(* --------------------------------- *)
(*                                   *)
(*         Player API Callbacks      *)
(*                                   *)
(* --------------------------------- *)

let find_game params =
	let gid = List.assoc "game_id" params |> int_of_string in
	List.assoc gid !lobby

let shoot req =
	let st  = find_game req.params in
	let pid = List.assoc "player_id" req.params in
	let gun_id = List.assoc "gun_id" req.params in
	fire st pid gun_id;
	Server.respond_string ~status:`OK ~body:"Ok." ()

let pos_from_json req =
	req.body 
	|> to_list
	|> List.map to_float
	|> fun lst -> match lst with [x;y] -> (x,y) | _ -> failwith "invalid json"

let move' req = 
	let st  = find_game req.params in
	let pid = List.assoc "player_id" req.params in
	let pos = pos_from_json req in
	move st pid pos;
	Server.respond_string ~status: `OK ~body:"Ok." () 



(* --------------------------------- *)
(*                                   *)
(*         State API Callbacks       *)
(*                                   *)
(* --------------------------------- *)


(* TODO ID OF REQUESTING PLAYER *)
let get_st req =
	req.params |> find_game |> to_description 


(* --------------------------------- *)
(*                                   *)
(*               Server              *)
(*                                   *)
(* --------------------------------- *)

(* A list of all callbacks. Each callback takes in
	 a request and returns a server response. There
	 is a callback for each API command. *)
let responses = [
	("/game",	  "GET"),  get_st;
	("/move",	  "POST"), move;
	("/shoot",  "GET"),  shoot;
	("/games",  "GET"),  get_lobbies;
	("/create", "POST"), create_game;
	("/join",   "GET"),  join_game;
]

(* Called whenever the server receives a request. *)
let callback responses _conn req body =
	let uri = req |> Request.uri in
	let meth = req |> Request.meth |> Code.string_of_method in
	let headers = req |> Request.headers |> Header.to_string in
		try
			let params = List.map (fun p -> ((fst p), List.hd (snd p))) (Uri.query uri) in
			let body = Cohttp_lwt.Body.to_string in
			{body;params} |> List.assoc (Uri.path uri,meth) responses
		with
		| Not_found -> failwith "invalid URI"

(* Runs the server on [port]. *)
let run ?(port = 8080) =
	let server = 
		Server.create ~mode:(`TCP (`Port port)) (Server.make (callback responses) ()) 
	in
	ignore (Lwt_main.run server)
