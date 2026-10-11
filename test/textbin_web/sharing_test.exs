defmodule TextbinWeb.SharingTest do
  use ExUnit.Case, async: true

  alias TextbinWeb.Sharing

  test "every stored value has a label and a sentence" do
    for audience <- Sharing.audiences() do
      assert Sharing.audience_label(audience) != audience
      assert Sharing.audience_sentence(audience, "Docs") =~ "can see this paste"
    end

    for {label, policy} <- Sharing.sharing_policy_options() do
      assert label != policy
      assert is_binary(Sharing.sharing_policy_sentence(policy))
    end

    for {label, visibility} <- Sharing.join_policy_options() do
      assert label != visibility
      assert is_binary(Sharing.join_policy_sentence(visibility))
    end
  end

  test "unknown values from old audit metadata fall back to the raw value" do
    assert Sharing.sharing_policy_label("retired") == "retired"
    assert Sharing.join_policy_label("retired") == "retired"
    assert Sharing.audience_label("retired") == "retired"
  end
end
