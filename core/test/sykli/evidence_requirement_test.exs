defmodule Sykli.EvidenceRequirementTest do
  use ExUnit.Case, async: true

  alias Sykli.EvidenceRequirement

  test "parses and normalizes file evidence requirements" do
    assert {:ok,
            [
              %{
                "type" => "file",
                "name" => "coverage",
                "required" => true,
                "visibility" => "local",
                "predicate" => "exists",
                "ref_pattern" => "coverage.out"
              }
            ]} =
             EvidenceRequirement.parse(
               [%{"type" => "file", "name" => "coverage", "ref_pattern" => "coverage.out"}],
               :task,
               "4",
               "test"
             )
  end

  test "rejects evidence_required before version 4" do
    assert {:error, {:evidence_required_requires_version_4, "test", "3"}} =
             EvidenceRequirement.parse(
               [%{"type" => "file", "name" => "coverage", "ref_pattern" => "coverage.out"}],
               :task,
               "3",
               "test"
             )
  end

  test "accepts evidence_required in version 5" do
    assert {:ok, [%{"type" => "file", "name" => "coverage"} = requirement]} =
             EvidenceRequirement.parse(
               [%{"type" => "file", "name" => "coverage", "ref_pattern" => "coverage.out"}],
               :task,
               "5",
               "test"
             )

    assert requirement["ref_pattern"] == "coverage.out"
  end

  test "rejects invalid file evidence shape" do
    assert {:error, {:invalid_evidence_required, "test", "requires ref_pattern"}} =
             EvidenceRequirement.parse(
               [%{"type" => "file", "name" => "coverage"}],
               :task,
               "4",
               "test"
             )
  end

  test "unsupported_results builds target-owned result records" do
    [result] =
      EvidenceRequirement.unsupported_results(
        [%{"type" => "attestation", "name" => "slsa"}],
        "k8s",
        "unsupported"
      )

    assert result.status == :unsupported
    assert result.type == "attestation"
    assert result.name == "slsa"
    assert result.target == "k8s"
  end
end
