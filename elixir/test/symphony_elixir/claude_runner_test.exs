defmodule SymphonyElixir.ClaudeRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.{Runner, StreamParser}

  describe "StreamParser.parse_line/1" do
    test "parses system init event" do
      line = ~s({"type":"system","subtype":"init","session_id":"sess-1","tools":[]})
      assert {:ok, event} = StreamParser.parse_line(line)
      assert event.type == "system"
      assert event.subtype == "init"
      assert event.session_id == "sess-1"
    end

    test "parses assistant text event" do
      line = ~s({"type":"assistant","subtype":"text","content":"Working on it..."})
      assert {:ok, event} = StreamParser.parse_line(line)
      assert event.type == "assistant"
      assert event.subtype == "text"
      assert event.content == "Working on it..."
    end

    test "parses result success event with usage" do
      line =
        ~s({"type":"result","subtype":"success","result":"Done","session_id":"sess-1","usage":{"input_tokens":100,"output_tokens":50}})

      assert {:ok, event} = StreamParser.parse_line(line)
      assert event.type == "result"
      assert event.subtype == "success"
      assert event.session_id == "sess-1"
      assert event.content == "Done"
      assert event.usage == %{"input_tokens" => 100, "output_tokens" => 50, "total_tokens" => 150}
    end

    test "parses result error event" do
      line = ~s({"type":"result","subtype":"error","error":"something went wrong"})
      assert {:ok, event} = StreamParser.parse_line(line)
      assert event.type == "result"
      assert event.subtype == "error"
      assert event.error == "something went wrong"
    end

    test "parses tool_use event" do
      line = ~s({"type":"tool_use","tool":"Read","input":{"file_path":"/tmp/test.txt"}})
      assert {:ok, event} = StreamParser.parse_line(line)
      assert event.type == "tool_use"
    end

    test "parses tool_result event" do
      line = ~s({"type":"tool_result","tool":"Read","content":"file contents"})
      assert {:ok, event} = StreamParser.parse_line(line)
      assert event.type == "tool_result"
      assert event.content == "file contents"
    end

    test "returns error for empty line" do
      assert {:error, :empty_line} = StreamParser.parse_line("")
      assert {:error, :empty_line} = StreamParser.parse_line("   ")
    end

    test "returns error for invalid JSON" do
      assert {:error, {:json_decode_error, _}} = StreamParser.parse_line("not json")
    end

    test "returns error for JSON without type field" do
      assert {:error, {:missing_type, _}} = StreamParser.parse_line(~s({"foo":"bar"}))
    end
  end

  describe "Runner.start_session/2" do
    test "validates workspace and returns session struct" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-start-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MT-100")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_provider: "claude"
        )

        assert {:ok, session} = Runner.start_session(workspace)
        assert String.ends_with?(session.workspace, "workspaces/MT-100")
        assert session.session_id == nil
        assert session.worker_host == nil
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects workspace outside workspace root" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-reject-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        outside = Path.join(test_root, "outside")
        File.mkdir_p!(workspace_root)
        File.mkdir_p!(outside)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_provider: "claude"
        )

        assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}} =
                 Runner.start_session(outside)
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "Runner.run_turn/4" do
    test "single turn completes successfully with events" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-single-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MT-200")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        echo '{"type":"system","subtype":"init","session_id":"sess-test-1","tools":[]}'
        echo '{"type":"assistant","subtype":"text","content":"Working..."}'
        echo '{"type":"result","subtype":"success","result":"Done","session_id":"sess-test-1","usage":{"input_tokens":100,"output_tokens":50}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_provider: "claude",
          codex_claude_command: fake_claude
        )

        issue = %Issue{
          id: "issue-claude-1",
          identifier: "MT-200",
          title: "Test single turn",
          description: "Test Claude single turn",
          state: "In Progress",
          url: "https://example.org/issues/MT-200",
          labels: ["backend"]
        }

        test_pid = self()

        on_message = fn message ->
          send(test_pid, {:claude_event, message.event})
        end

        assert {:ok, session} = Runner.start_session(workspace)

        assert {:ok, updated_session} =
                 Runner.run_turn(session, "Do the thing", issue, on_message: on_message)

        assert updated_session.session_id == "sess-test-1"

        # Verify we received the expected events
        assert_received {:claude_event, :session_started}
        assert_received {:claude_event, :notification}
        assert_received {:claude_event, :turn_completed}
      after
        File.rm_rf(test_root)
      end
    end

    test "multi-turn uses --resume flag on second turn" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-multi-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MT-201")
        fake_claude = Path.join(test_root, "fake-claude")
        trace_file = Path.join(test_root, "claude-args.trace")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        echo "$@" >> "#{trace_file}"
        echo '{"type":"system","subtype":"init","session_id":"sess-resume-1","tools":[]}'
        echo '{"type":"result","subtype":"success","result":"Done","session_id":"sess-resume-1","usage":{"input_tokens":50,"output_tokens":25}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_provider: "claude",
          codex_claude_command: fake_claude
        )

        issue = %Issue{
          id: "issue-claude-2",
          identifier: "MT-201",
          title: "Test multi turn",
          description: "Test Claude multi turn",
          state: "In Progress",
          url: "https://example.org/issues/MT-201",
          labels: ["backend"]
        }

        assert {:ok, session} = Runner.start_session(workspace)

        # First turn — no resume flag
        assert {:ok, session_after_turn1} = Runner.run_turn(session, "First turn", issue)
        assert session_after_turn1.session_id == "sess-resume-1"

        # Second turn — should include --resume
        assert {:ok, _session_after_turn2} =
                 Runner.run_turn(session_after_turn1, "Second turn", issue)

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        # First turn should NOT contain --resume
        refute String.contains?(Enum.at(lines, 0), "--resume")
        # Second turn SHOULD contain --resume sess-resume-1
        assert String.contains?(Enum.at(lines, 1), "--resume")
        assert String.contains?(Enum.at(lines, 1), "sess-resume-1")
      after
        File.rm_rf(test_root)
      end
    end

    test "non-zero exit code returns error" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-exit-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MT-202")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        echo '{"type":"system","subtype":"init","session_id":"sess-err","tools":[]}'
        exit 1
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_provider: "claude",
          codex_claude_command: fake_claude
        )

        issue = %Issue{
          id: "issue-claude-err",
          identifier: "MT-202",
          title: "Test error",
          description: "Test Claude error handling",
          state: "In Progress",
          url: "https://example.org/issues/MT-202",
          labels: ["backend"]
        }

        assert {:ok, session} = Runner.start_session(workspace)
        assert {:error, {:port_exit, 1}} = Runner.run_turn(session, "Fail", issue)
      after
        File.rm_rf(test_root)
      end
    end

    test "result error event returns turn_failed" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-result-err-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MT-203")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        echo '{"type":"system","subtype":"init","session_id":"sess-fail","tools":[]}'
        echo '{"type":"result","subtype":"error","error":"Model overloaded"}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_provider: "claude",
          codex_claude_command: fake_claude
        )

        issue = %Issue{
          id: "issue-claude-fail",
          identifier: "MT-203",
          title: "Test result error",
          description: "Test Claude result error handling",
          state: "In Progress",
          url: "https://example.org/issues/MT-203",
          labels: ["backend"]
        }

        assert {:ok, session} = Runner.start_session(workspace)

        assert {:error, {:turn_failed, "Model overloaded"}} =
                 Runner.run_turn(session, "Fail gracefully", issue)
      after
        File.rm_rf(test_root)
      end
    end

    test "malformed JSON lines are tolerated and turn still completes" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-malformed-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MT-204")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        echo '{"type":"system","subtype":"init","session_id":"sess-mal","tools":[]}'
        echo 'this is not json'
        echo '{"type":"result","subtype":"success","result":"OK","session_id":"sess-mal","usage":{"input_tokens":10,"output_tokens":5}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_provider: "claude",
          codex_claude_command: fake_claude
        )

        issue = %Issue{
          id: "issue-claude-mal",
          identifier: "MT-204",
          title: "Test malformed",
          description: "Test malformed JSON tolerance",
          state: "In Progress",
          url: "https://example.org/issues/MT-204",
          labels: ["backend"]
        }

        assert {:ok, session} = Runner.start_session(workspace)
        assert {:ok, updated} = Runner.run_turn(session, "Work", issue)
        assert updated.session_id == "sess-mal"
      after
        File.rm_rf(test_root)
      end
    end

    test "stop_session is a no-op" do
      assert :ok = Runner.stop_session(%{session_id: "test", workspace: "/tmp"})
    end
  end

  describe "Runner.run_turn/4 with --dangerously-skip-permissions" do
    test "adds flag when approval_policy rejects sandbox_approval, rules, and mcp_elicitations" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-perms-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MT-205")
        fake_claude = Path.join(test_root, "fake-claude")
        trace_file = Path.join(test_root, "claude-perms.trace")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        echo "$@" >> "#{trace_file}"
        echo '{"type":"system","subtype":"init","session_id":"sess-perms","tools":[]}'
        echo '{"type":"result","subtype":"success","result":"OK","session_id":"sess-perms","usage":{"input_tokens":10,"output_tokens":5}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_provider: "claude",
          codex_claude_command: fake_claude,
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}}
        )

        issue = %Issue{
          id: "issue-claude-perms",
          identifier: "MT-205",
          title: "Test permissions",
          description: "Test skip permissions flag",
          state: "In Progress",
          url: "https://example.org/issues/MT-205",
          labels: ["backend"]
        }

        assert {:ok, session} = Runner.start_session(workspace)
        assert {:ok, _} = Runner.run_turn(session, "Test", issue)

        trace = File.read!(trace_file)
        assert String.contains?(trace, "--dangerously-skip-permissions")
      after
        File.rm_rf(test_root)
      end
    end
  end
end
