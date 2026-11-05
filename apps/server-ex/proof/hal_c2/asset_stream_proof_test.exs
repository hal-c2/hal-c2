defmodule HalC2.AssetStreamProofTest do
  # One signed asset body crosses from its issuing MC to a requesting process in
  # acknowledged chunks. This explores every message order, crash, disconnect,
  # partition and timeout up to the bounds.
  @storage "attachment storage, URL signing and token verification carry no response body"

  use HalC2.Proof,
    model: "asset_stream.maude",
    module: "ASSET-STREAM",
    check: "ASSET-STREAM-PROPS",
    timeout: 900_000,
    code: [
      {:exports, HalC2.Attachments},
      {:exports, HalC2.Attachments.GitHubMedia}
    ],
    covers: %{
      "HalC2.Attachments.serve/2" => ~w(open offer consume accept finish),
      "HalC2.Attachments.GitHubMedia.serve/2" => ~w(open offer consume accept finish)
    },
    abstracts: %{
      "HalC2.Attachments.create_upload_url/2" => @storage,
      "HalC2.Attachments.max_image_bytes/0" => @storage,
      "HalC2.Attachments.store/2" => @storage,
      "HalC2.Attachments.delete/1" => @storage,
      "HalC2.Attachments.delete_thread/1" => @storage,
      "HalC2.Attachments.claim/2" => @storage,
      "HalC2.Attachments.persist/1" => @storage,
      "HalC2.Attachments.path/1" => @storage,
      "HalC2.Attachments.valid_id?/1" => @storage,
      "HalC2.Attachments.prompt_text/2" => @storage,
      "HalC2.Attachments.native_images/1" => @storage,
      "HalC2.Attachments.create_url/2" => @storage,
      "HalC2.Attachments.issuer/1" => @storage,
      "HalC2.Attachments.chunk_bytes/0" =>
        "the byte bound is checked by the unit and feature tests; the model counts chunks",
      "HalC2.Attachments.dir/0" => @storage,
      "HalC2.Attachments.GitHubMedia.fetch_url/1" =>
        "selects the upstream URL; it changes no chunk order or backpressure",
      "HalC2.Attachments.GitHubMedia.file_name/1" =>
        "the display name changes no chunk order or backpressure"
    },
    environment: %{
      "stop" => "the consumer disconnects and the producer aborts",
      "crash" => "the producer or its consumer dies and the request ends",
      "partition" => "the cluster link drops the chunk or ack in flight",
      "heal" => "the cluster link comes back",
      "time-out" => "a producer waiting for its consumer gives up"
    },
    scenarios: %{
      "mc/platform/attachments-and-assets.feature" => [
        "Upload and asset URLs work through any MC of the cluster",
        "Large media streams in bounded pieces"
      ]
    }

  @fair ~w(open offer consume accept finish)

  test "no interleaving puts more than one unacknowledged chunk in flight", %{proof: proof} do
    refute_reachable(proof, "start(4, 2, 2)", "unsafe", [])
  end

  test "a request always finishes or aborts", %{proof: proof} do
    refute_deadlock(proof, "start(4, 1, 1)", "settled", besides: ~w(crash partition heal))
  end

  test "an undisrupted request delivers every chunk", %{proof: proof} do
    assert_ltl(proof, "start(4, 0, 0)", "<> complete", fair: @fair)
  end
end
