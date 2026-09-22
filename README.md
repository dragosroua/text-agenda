# Text agenda

`agenda.sh` is a terminal agenda for the day files in this folder. It draws a calendar on the left and the tasks for the selected day on the right. Bash 3.2 is enough. Nothing else needs to be installed.

The window needs at least 80 columns and 24 rows. A wider window gives the tasks more room, and a line that does not fit continues on the next row.

## Run it

```bash
./agenda.sh
```

It opens on today. `./agenda.sh --check` loads every day file, checks that each filename's weekday matches the date, and checks the calendar arithmetic. It does not open the screen.

## Day files

Each day is a plain text file named `weekday-DD-MM-YYYY`, with the English weekday in lowercase, for example `tuesday-22-09-2026`. The script reads and writes only those files. A day with no tasks has no file. The file is created when you add the first task.

A line is one of these:

- `x task` is done.
- `- task` is still open.
- A leading tab makes the line a subtask of the task above it. One tab is one level.
- A line with no mark, followed by tabbed lines, is a parent task with no status.
- Any other line with no mark is a label, such as `leftovers` or `to assess`.

The tasks above the first label belong to the day itself. A blank line separates labels.

## The screen

The year is at the top of the left column, then the month, then the days. Monday is the first column. Today is underlined. The selected day is shown in reverse. A day that has a file is marked: `*` when something is still open, `.` when every task is done.

Under the calendar are the labels for that day, each with its count of open tasks. The highlighted label is the one open on the right.

The right side is the date, the label, and its tasks. An open task's `-` is yellow. A finished task's `x` is green, and its words are dim. A `*` beside the date means the write to disk has not finished.

## Keys

Left and right change whatever is highlighted: the year, the month, or the day. Up and down move between the year, the month, the days, and the labels. `J` and `K` on the calendar jump a week. Tab moves between the left column and the tasks. `t` returns to today. `g` asks for a date as `DD-MM-YYYY`.

`a` adds a task and `e` edits one. Both work from the calendar and from the task list. On a task, `x` toggles done, `>` and `<` change the indent, `d` deletes the task and its subtasks, and `J` and `K` move it. `m` moves it to another label. `X` marks every task in the current label done. `c` copies the open tasks in the current label to a date you type. Enter alone means tomorrow.

On the label list, `l` adds a label, `r` renames it, `d` deletes it and moves its tasks into the day, and `J` and `K` reorder the labels.

`/` searches every day file. `n` and `N` move through the hits, and Enter opens the one you are on. `u` undoes and Ctrl-R redoes, up to 30 steps on the open day. `s` writes the file now. Every change is also written as soon as you make it. `q` quits. `?` lists the keys inside the program.

This was built with Grok-4.7 as a test.
