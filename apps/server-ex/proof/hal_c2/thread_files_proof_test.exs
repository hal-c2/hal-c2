defmodule HalC2.ThreadFilesProofTest do
  # The files a thread's messages carry, a message too long to send whole among them,
  # through every interleaving of sends, a move to another MC, forks and deletes, with
  # a send dying between writing its file and its message.
  # prop/hal_c2/thread_files_prop_test.exs runs the code on sequences of these; this
  # explores every order of their steps.
  #
  # Each part of the design is a switch in the model, and each test below turns one off
  # to find the flaw it closes:
  #
  #   - A message written before its file shows a file that is not there, until the
  #     file is written, or forever if the send dies; a move in between carries the
  #     message without it.
  #   - A fork whose messages name its source's files loses them when the source is
  #     deleted.
  #   - A fork that copies from what it read of its source, without looking again once
  #     it has copied, takes a source deleted meanwhile, whose files were gone before
  #     they could be copied.
  #   - A move that sends the archive it built before the thread changed loses the
  #     message that changed it.
  @archive "builds, reads or writes archive files around a move or an import; the model has what a move carries"
  @upload "a client's upload before a message claims it, or serving a stored one"
  @files "names a file or reads it for a prompt; no file is written or removed by it"

  use HalC2.Proof,
    model: "thread_files.maude",
    module: "THREAD-FILES",
    check: "THREAD-FILES-PROPS",
    code: [
      {:exports, HalC2.Attachments},
      {:exports, HalC2.Orchestration.Fork},
      {:exports, HalC2.ThreadArchive}
    ],
    covers: %{
      "HalC2.Attachments.fold_long_text/3" => ~w(fold),
      "HalC2.Attachments.claim/2" => ~w(fold),
      "HalC2.Attachments.copy_into/2" => ~w(copy),
      "HalC2.Attachments.delete_thread/1" => ~w(cleanup rmfiles),
      "HalC2.Attachments.path/1" => ~w(hasFile carried copy),
      "HalC2.Orchestration.Fork.fork/1" => ~w(fork fork-gone read copy forked),
      "HalC2.ThreadArchive.build/2" => ~w(build rebuild carried),
      "HalC2.ThreadArchive.import_archive/2" => ~w(import placed)
    },
    abstracts: %{
      "HalC2.Attachments.create_upload_url/2" => @upload,
      "HalC2.Attachments.store/2" => @upload,
      "HalC2.Attachments.delete/1" => @upload,
      "HalC2.Attachments.persist/1" => @upload,
      "HalC2.Attachments.create_url/2" => @upload,
      "HalC2.Attachments.serve/2" => @upload,
      "HalC2.Attachments.issuer/1" => @upload,
      "HalC2.Attachments.max_image_bytes/0" => @upload,
      "HalC2.Attachments.chunk_bytes/0" => @upload,
      "HalC2.Attachments.dir/0" => @files,
      "HalC2.Attachments.native_images/1" => @files,
      "HalC2.Attachments.prompt_text/2" => @files,
      "HalC2.Attachments.thread_segment/1" => @files,
      "HalC2.Attachments.valid_id?/1" => @files,
      "HalC2.Orchestration.Fork.merge_back/1" =>
        "queues a fork's work for its parent; it copies no message and no file",
      "HalC2.ThreadArchive.checkpoints_note/3" => @archive,
      "HalC2.ThreadArchive.clear_scratch/0" => @archive,
      "HalC2.ThreadArchive.decode/1" => @archive,
      "HalC2.ThreadArchive.describe/1" => @archive,
      "HalC2.ThreadArchive.discard/1" => @archive,
      "HalC2.ThreadArchive.encode/1" => @archive,
      "HalC2.ThreadArchive.export_file/3" => @archive,
      "HalC2.ThreadArchive.exportable/1" => @archive,
      "HalC2.ThreadArchive.extension/0" => @archive,
      "HalC2.ThreadArchive.files/1" => @archive,
      "HalC2.ThreadArchive.files_on_disk/2" => @archive,
      "HalC2.ThreadArchive.find_thread/1" => @archive,
      "HalC2.ThreadArchive.import_file/2" =>
        "a thread file a user imports, which import_archive/2 takes as a move does",
      "HalC2.ThreadArchive.kinds/1" => @archive,
      "HalC2.ThreadArchive.label/0" => @archive,
      "HalC2.ThreadArchive.local_projects/0" => @archive,
      "HalC2.ThreadArchive.local_thread/1" => @archive,
      "HalC2.ThreadArchive.map_files/2" => @archive,
      "HalC2.ThreadArchive.repository/1" => @archive,
      "HalC2.ThreadArchive.resolve_project/2" => @archive,
      "HalC2.ThreadArchive.rewriter/4" => @archive,
      "HalC2.ThreadArchive.same_repository/2" => @archive,
      "HalC2.ThreadArchive.summary/1" => @archive,
      "HalC2.ThreadArchive.v1_terminal/2" => @archive
    },
    environment: %{
      "append" =>
        "the thread's stream writes the message naming the file (Orchestration's message.dispatch and queued-run.edit)",
      "refuse" =>
        "the thread's stream refuses the message of a thread no longer live here, and Orchestration removes the file no message names",
      "tell" => "a send that writes its message before its file; only with Ahead off",
      "write" => "the file of a send that wrote its message first; only with Ahead off",
      "crash" => "the process sending dies between its two steps",
      "begin" =>
        "ThreadMove marks the thread moving (begin/4); the move's own protocol is thread_move.maude's",
      "called-off" => "a move of a thread that is not live here is refused",
      "release" => "a move that does not finish leaves the thread live here again",
      "delete" =>
        "thread.delete marks the thread deleted, refused while it moves, and records its cleanup",
      "delete-gone" => "a delete of a thread that is not here is refused"
    },
    scenarios: %{
      "mc/orchestration/composer-context.feature" => [
        "A message over 120,000 characters reaches the agent as a file"
      ],
      "threads/fork-and-lineage.feature" => [
        "A fork keeps the files its messages carry when the thread it came from is deleted"
      ]
    }

  # Ahead, Own, Recheck, Rebuild.
  @design "true, true, true, true"
  @faults ~w(crash)

  # Two long messages, a move, a fork and deletes of both threads.
  @moving "send(1, 1) send(1, 2) move(1) fork(1, 2) del(1) del(2)"
  # A fork that is sent to, moved and forked again while its source is deleted.
  @forking "send(1, 1) fork(1, 2) send(2, 2) move(2) del(1) fork(2, 3) del(2)"

  test "no live thread shows a file it does not have, and no move loses a message",
       %{proof: proof} do
    refute_reachable(proof, "start(#{@design}, 1, #{@moving})", "unsafe", [])
    refute_reachable(proof, "start(#{@design}, 1, #{@forking})", "unsafe", [])
  end

  # A send that dies between its steps leaves its file until its thread is deleted; with
  # no fault every file is named by a message of a thread on its MC.
  test "nothing leaves a file no message names", %{proof: proof} do
    refute_reachable(proof, "start(#{@design}, 0, #{@moving})", "leftover", [])
    refute_reachable(proof, "start(#{@design}, 0, #{@forking})", "leftover", [])
  end

  test "every send, move, fork and delete ends", %{proof: proof} do
    refute_deadlock(proof, "start(#{@design}, 1, #{@moving})", "settled", besides: @faults)
    refute_deadlock(proof, "start(#{@design}, 1, #{@forking})", "settled", besides: @faults)
    assert_ltl(proof, "start(#{@design}, 0, #{@moving})", "<> [] finished", [])
  end

  test "a message written before its file shows one that is not there", %{proof: proof} do
    assert_reachable(proof, "start(false, true, true, true, 1, send(1, 1) move(1))", "unsafe")
  end

  test "a fork naming its source's files loses them with the source", %{proof: proof} do
    init = "start(true, false, true, true, 0, send(1, 1) fork(1, 2) del(1))"
    assert_reachable(proof, init, "dangling")
  end

  test "a fork that does not look at its source again takes one deleted while it copied",
       %{proof: proof} do
    init = "start(true, true, false, true, 0, send(1, 1) fork(1, 2) del(1))"
    assert_reachable(proof, init, "dangling")
  end

  test "a move that sends an archive built before the thread changed loses a message",
       %{proof: proof} do
    assert_reachable(proof, "start(true, true, true, false, 0, send(1, 1) move(1))", "lost")
  end
end
