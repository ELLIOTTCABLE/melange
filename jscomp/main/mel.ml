(* Copyright (C) 2015-2016 Bloomberg Finance L.P.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * In addition to the permissions granted to you by the LGPL, you may combine
 * or link a "work that uses the Library" with a publicly distributed version
 * of this file to produce a combined library or application, then distribute
 * that combined work under the terms of your choosing, with no requirement
 * to comply with the obligations normally placed on you by section 4 of the
 * LGPL version 3 (or the corresponding section of a later version of the LGPL
 * should you choose to use a later version).
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA. *)

open Cmdliner
open Bsb

let () = Bsb_log.setup ()
let ( // ) = Ext_path.combine

let output_dune_project_if_does_not_exist proj_dir =
  let dune_project = proj_dir // Literals.dune_project in
  if Sys.file_exists dune_project then ()
  else
    let ochan = open_out_bin dune_project in
    output_string ochan "(lang dune 2.8)\n";
    output_string ochan "(using action-plugin 0.1)\n";
    close_out ochan

let output_dune_file buf =
  (* <root>/dune.bsb generation *)
  let proj_dir = Bsb_global_paths.cwd in
  let dune_bsb = proj_dir // Literals.dune_mel in
  Bsb_ninja_targets.revise_dune dune_bsb buf;

  (* <root>/dune generation *)
  let dune = proj_dir // Literals.dune in
  let buf = Buffer.create 256 in
  Buffer.add_string buf "\n(include ";
  Buffer.add_string buf Literals.dune_mel;
  Buffer.add_string buf ")\n";
  Bsb_ninja_targets.revise_dune dune buf;
  output_dune_project_if_does_not_exist proj_dir

let dune_command_exit dune_args =
  let common_args = [| Literals.dune; "build"; "@" ^ Literals.bsb_world |] in
  let args = Array.append common_args dune_args in
  Bsb_log.info "@{<info>Running:@} %s@."
    (String.concat " " (Array.to_list args));
  Unix.execvp Literals.dune args

let build_whole_project () =
  let root_dir = Bsb_global_paths.cwd in
  let buf = Buffer.create 0x1000 in
  let config, dep_configs = Bsb_world.make_world_deps ~buf ~cwd:root_dir in
  Bsb_ninja_regen.regenerate_ninja ~package_kind:Toplevel ~buf ~root_dir ~config
    root_dir;
  output_dune_file buf;
  config :: dep_configs

module Common_opts = struct
  open Cmdliner

  type t = { verbose : bool }

  let make verbose = { verbose }

  let verbose_flag =
    let doc = "Print debug output" in
    Arg.(value & flag & info [ "v"; "verbose" ] ~doc)

  let copts_t = Term.(const make $ verbose_flag)
end

type cli_options = { where : bool }

module Actions = struct
  let wrap_bsb ~opts:{ Common_opts.verbose } ~f =
    if verbose then Bsb_log.verbose ();
    try f () with
    | Bsb_exception.Error e ->
        Bsb_exception.print Format.err_formatter e;
        Format.pp_print_newline Format.err_formatter ();
        exit 2
    | Ext_json_parse.Error (start, _, e) ->
        Format.fprintf Format.err_formatter
          "File %S, line %d\n@{<error>Error:@} %a@." start.pos_fname
          start.pos_lnum Ext_json_parse.report_error e;
        exit 2
    | Sys_error s ->
        Format.fprintf Format.err_formatter "@{<error>Error:@} %s@." s;
        exit 2
    | e -> Ext_pervasives.reraise e

  let do_output_rules () =
    let configs = build_whole_project () in
    Bsb_world.install_targets Bsb_global_paths.cwd configs

  let build opts watch_mode dune_args =
    wrap_bsb ~opts ~f:(fun () ->
        do_output_rules ();
        if watch_mode then (
          prerr_endline "watch mode not supported yet";
          exit 0)
        else dune_command_exit dune_args)

  let rules opts = wrap_bsb ~opts ~f:do_output_rules

  let clean opts dune_args =
    wrap_bsb ~opts ~f:(fun () ->
        Bsb_clean.clean ~dune_args Bsb_global_paths.cwd)

  let default opts { where } dune_args =
    if where then print_endline (Filename.dirname Sys.executable_name)
    else build opts false dune_args
end

module Commands = struct
  let watch_mode_flag =
    let doc = "Currently does nothing. Enabled for compatibility." in
    Arg.(value & flag & info [ "w" ] ~doc)

  let build dune_args =
    let doc = "build the project in the current directory" in
    let man =
      [
        `S Manpage.s_description;
        `P "Builds the Melange project in the current directory.";
      ]
    in
    let info = Cmd.info "build" ~doc ~man in
    Cmd.v info
      Term.(
        const Actions.build $ Common_opts.copts_t $ watch_mode_flag
        $ const dune_args)

  let rules (_dune_args : string array) =
    let doc = "Output the dune rules necessary to build the project" in
    let man =
      [
        `S Manpage.s_description;
        `P
          "Outputs the dune rules necessary to build the project in the \n\
           in the current directory and exits. This command does NOT build \n\
           the project.";
      ]
    in
    let info = Cmd.info "rules" ~doc ~man in
    Cmd.v info Term.(const Actions.rules $ Common_opts.copts_t)

  let clean dune_args =
    let doc = "Clean the project" in
    let man =
      [
        `S Manpage.s_description;
        `P "Cleans the project in the current directory and exits.";
      ]
    in
    let info = Cmd.info "clean" ~doc ~man in
    Cmd.v info
      Term.(const Actions.clean $ Common_opts.copts_t $ const dune_args)

  let commands = [ build; rules; clean ]
end

module CLI = struct
  let where_flag =
    let doc = "Show where bsb is located" in
    Arg.(value & flag & info [ "where" ] ~doc)

  let parse_options where = { where }

  let default dune_args =
    let make_bsb_options = Term.(const parse_options $ where_flag) in
    Term.(
      const Actions.default $ Common_opts.copts_t $ make_bsb_options
      $ const dune_args)

  let run dune_args =
    let open Cmdliner in
    let doc = "the Melange buildpack" in
    let info = Cmd.info "mel" ~version:Bs_version.version ~doc in
    let default = default dune_args in
    Cmd.group info ~default (List.map (fun f -> f dune_args) Commands.commands)
end

let () =
  let bsb_args, dune_args = Ext_cli_args.split_argv_at_separator Sys.argv in
  exit
    (Cmd.eval ~argv:(Ext_cli_args.normalize_argv bsb_args) (CLI.run dune_args))
