# Muse Code

HAL-C2 can run Muse Code with your existing Muse installation and login. Muse Code support is in
beta and stays off until you enable it.

## Set up Muse Code

1. Install Muse Code on the machine running your environment.
2. Run `muse login` on that machine.
3. Open **Settings > Providers**, enable Muse Code, and refresh its status.

If `muse` is not on the server's `PATH`, set Muse Code's **Binary path** to the executable.
HAL-C2 cannot tell whether Muse Code is signed in. If Muse Code shows a warning and no models,
run `muse login` on that machine and refresh again.

## Models and reasoning

The model picker lists the models from Muse's catalog. Each model offers the reasoning levels Muse
reports for it under **Reasoning**, with Muse's default preselected.

## Permissions

Muse Code supports **Supervised** and **Full access**. **Auto-accept edits** and **Auto** are not
offered, and there is no plan mode. In **Supervised**, Muse Code asks before running commands and
changing files; answer its approvals and questions in the conversation.

## In a thread

- Send a message while Muse Code is working to steer the running turn.
- Stop a turn to interrupt Muse Code.
- Send `/compact` to compact the conversation.
- Muse Code can use HAL-C2's tools, such as delegating work to another provider.

## Limitations

- A Muse Code thread cannot rewind its conversation to an earlier turn.
- Forking a Muse Code thread starts the fork from a summary of the earlier conversation instead of
  Muse Code's own session.
- Muse Code does not write thread titles, commit messages, or pull request text. Choose another
  provider for generated text.
