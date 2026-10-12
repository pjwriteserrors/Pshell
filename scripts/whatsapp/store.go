package main

import (
	"database/sql"
	"encoding/json"
	"os"
	"strings"
)

// What the shell knows of WhatsApp, kept in chats.db beside the session: the
// chats, their messages (with the message as WhatsApp sent it, so its media
// can be fetched later and it can be quoted or forwarded), reactions and the
// votes of polls.

// message status
const (
	statusFailed    = -1
	statusPending   = 0
	statusSent      = 1
	statusDelivered = 2
	statusRead      = 3
	statusPlayed    = 4
)

type Media struct {
	Mime     string `json:"mime,omitempty"`
	Size     uint64 `json:"size,omitempty"`
	Width    int    `json:"width,omitempty"`
	Height   int    `json:"height,omitempty"`
	Seconds  int    `json:"seconds,omitempty"`
	Name     string `json:"name,omitempty"`
	Path     string `json:"path,omitempty"`
	Thumb    string `json:"thumb,omitempty"`
	Animated bool   `json:"animated,omitempty"`
	ViewOnce bool   `json:"viewOnce,omitempty"`
	// why it could not be fetched
	Error string `json:"error,omitempty"`
}

type Quote struct {
	ID     string `json:"id"`
	Sender string `json:"sender"`
	Text   string `json:"text"`
}

type Poll struct {
	Options []string `json:"options"`
	Multi   bool     `json:"multi"`
}

type Place struct {
	Lat     float64 `json:"lat"`
	Lng     float64 `json:"lng"`
	Name    string  `json:"name,omitempty"`
	Address string  `json:"address,omitempty"`
	Live    bool    `json:"live,omitempty"`
}

type Card struct {
	Name   string   `json:"name"`
	Phones []string `json:"phones"`
	Vcard  string   `json:"vcard,omitempty"`
}

type Link struct {
	URL         string `json:"url"`
	Title       string `json:"title,omitempty"`
	Description string `json:"description,omitempty"`
	Thumb       string `json:"thumb,omitempty"`
}

type Extra struct {
	Media     *Media   `json:"media,omitempty"`
	Quote     *Quote   `json:"quote,omitempty"`
	Poll      *Poll    `json:"poll,omitempty"`
	Place     *Place   `json:"place,omitempty"`
	Cards     []Card   `json:"cards,omitempty"`
	Link      *Link    `json:"link,omitempty"`
	Mentions  []string `json:"mentions,omitempty"`
	Edited    bool     `json:"edited,omitempty"`
	Deleted   bool     `json:"deleted,omitempty"`
	Forwarded bool     `json:"forwarded,omitempty"`
	Starred   bool     `json:"starred,omitempty"`
	Error     string   `json:"error,omitempty"`
	// who sent it, as WhatsApp addressed them (a hidden address in some groups)
	Origin string `json:"origin,omitempty"`
}

type Row struct {
	Chat   string
	ID     string
	Sender string
	TS     int64
	Mine   bool
	Kind   string
	Text   string
	Extra  Extra
	Raw    []byte
	Status int
}

type ChatRow struct {
	JID       string
	Name      string
	Unread    int
	Pinned    int64
	Muted     int64
	Archived  bool
	Marked    bool
	Ephemeral int64
}

type Store struct {
	db *sql.DB
}

func openStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(10000)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	_ = os.Chmod(path, 0o600)
	_, err = db.Exec(`
		create table if not exists chats (
			jid text primary key, name text not null default '', unread integer not null default 0,
			pinned integer not null default 0, muted integer not null default 0, archived integer not null default 0,
			marked integer not null default 0, ephemeral integer not null default 0);
		create table if not exists messages (
			chat text not null, id text not null, sender text not null, ts integer not null, mine integer not null,
			kind text not null, text text not null default '', data text not null default '{}', raw blob,
			status integer not null default 0, primary key (chat, id));
		create index if not exists by_time on messages (chat, ts);
		create table if not exists reactions (
			chat text not null, id text not null, sender text not null, emoji text not null, ts integer not null,
			primary key (chat, id, sender));
		create table if not exists votes (
			chat text not null, id text not null, sender text not null, options text not null, ts integer not null,
			primary key (chat, id, sender));
		create table if not exists meta (key text primary key, value text not null);
	`)
	if err != nil {
		return nil, err
	}
	return &Store{db: db}, nil
}

// ── meta ────────────────────────────────────────────────────────────────
func (s *Store) get(key string) string {
	var value string
	_ = s.db.QueryRow("select value from meta where key = ?", key).Scan(&value)
	return value
}

func (s *Store) set(key, value string) {
	_, _ = s.db.Exec("insert or replace into meta values (?, ?)", key, value)
}

// ── chats ───────────────────────────────────────────────────────────────
func (s *Store) touch(jid string) {
	_, _ = s.db.Exec("insert or ignore into chats (jid) values (?)", jid)
}

func (s *Store) chatSet(jid, column string, value any) {
	s.touch(jid)
	_, _ = s.db.Exec("update chats set "+column+" = ? where jid = ?", value, jid)
}

func (s *Store) chat(jid string) ChatRow {
	row := ChatRow{JID: jid}
	_ = s.db.QueryRow("select name, unread, pinned, muted, archived, marked, ephemeral from chats where jid = ?", jid).
		Scan(&row.Name, &row.Unread, &row.Pinned, &row.Muted, &row.Archived, &row.Marked, &row.Ephemeral)
	return row
}

func (s *Store) chats() []ChatRow {
	rows, err := s.db.Query("select jid, name, unread, pinned, muted, archived, marked, ephemeral from chats")
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []ChatRow
	for rows.Next() {
		var row ChatRow
		if rows.Scan(&row.JID, &row.Name, &row.Unread, &row.Pinned, &row.Muted, &row.Archived, &row.Marked, &row.Ephemeral) == nil {
			out = append(out, row)
		}
	}
	return out
}

func (s *Store) dropChat(jid string, messagesOnly bool) {
	for _, table := range []string{"messages", "reactions", "votes"} {
		_, _ = s.db.Exec("delete from "+table+" where chat = ?", jid)
	}
	if !messagesOnly {
		_, _ = s.db.Exec("delete from chats where jid = ?", jid)
	}
}

// a chat that went on under another address (a phone number became known for it)
func (s *Store) moveChat(from, to string) {
	for _, table := range []string{"messages", "reactions", "votes"} {
		_, _ = s.db.Exec("update or ignore "+table+" set chat = ? where chat = ?", to, from)
		_, _ = s.db.Exec("delete from "+table+" where chat = ?", from)
	}
	s.touch(to)
	_, _ = s.db.Exec("update chats set unread = unread + (select unread from chats where jid = ?) where jid = ?", from, to)
	_, _ = s.db.Exec("delete from chats where jid = ?", from)
}

// ── messages ────────────────────────────────────────────────────────────
const columns = "chat, id, sender, ts, mine, kind, text, data, raw, status"

func scan(rows interface{ Scan(...any) error }) (*Row, error) {
	var row Row
	var data string
	if err := rows.Scan(&row.Chat, &row.ID, &row.Sender, &row.TS, &row.Mine, &row.Kind, &row.Text, &data, &row.Raw, &row.Status); err != nil {
		return nil, err
	}
	_ = json.Unmarshal([]byte(data), &row.Extra)
	return &row, nil
}

// put stores a message; one that is known keeps its place. Reports whether it is new.
func (s *Store) put(row *Row) bool {
	data, _ := json.Marshal(row.Extra)
	result, err := s.db.Exec("insert or ignore into messages ("+columns+") values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		row.Chat, row.ID, row.Sender, row.TS, row.Mine, row.Kind, row.Text, string(data), row.Raw, row.Status)
	if err != nil {
		return false
	}
	s.touch(row.Chat)
	added, _ := result.RowsAffected()
	return added > 0
}

func (s *Store) update(row *Row) {
	data, _ := json.Marshal(row.Extra)
	_, _ = s.db.Exec("update messages set sender = ?, ts = ?, kind = ?, text = ?, data = ?, raw = ?, status = ? where chat = ? and id = ?",
		row.Sender, row.TS, row.Kind, row.Text, string(data), row.Raw, row.Status, row.Chat, row.ID)
}

func (s *Store) message(chat, id string) *Row {
	row, err := scan(s.db.QueryRow("select "+columns+" from messages where chat = ? and id = ?", chat, id))
	if err != nil {
		return nil
	}
	return row
}

func (s *Store) remove(chat, id string) {
	_, _ = s.db.Exec("delete from messages where chat = ? and id = ?", chat, id)
	_, _ = s.db.Exec("delete from reactions where chat = ? and id = ?", chat, id)
	_, _ = s.db.Exec("delete from votes where chat = ? and id = ?", chat, id)
}

func (s *Store) query(where string, args ...any) []*Row {
	rows, err := s.db.Query("select "+columns+" from messages "+where, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []*Row
	for rows.Next() {
		if row, err := scan(rows); err == nil {
			out = append(out, row)
		}
	}
	return out
}

// the chat's last messages, oldest first
func (s *Store) last(chat string, count int) []*Row {
	rows := s.query("where chat = ? order by ts desc, rowid desc limit ?", chat, count)
	for i, j := 0, len(rows)-1; i < j; i, j = i+1, j-1 {
		rows[i], rows[j] = rows[j], rows[i]
	}
	return rows
}

func (s *Store) count(chat string) int {
	var count int
	_ = s.db.QueryRow("select count(*) from messages where chat = ?", chat).Scan(&count)
	return count
}

func (s *Store) oldest(chat string) *Row {
	rows := s.query("where chat = ? order by ts, rowid limit 1", chat)
	if len(rows) == 0 {
		return nil
	}
	return rows[0]
}

// what the chat list shows of every chat: its last message
func (s *Store) lasts() map[string]*Row {
	out := map[string]*Row{}
	for _, row := range s.query("where rowid in (select rowid from (select rowid, row_number() over (partition by chat order by ts desc, rowid desc) as place from messages) where place = 1)") {
		out[row.Chat] = row
	}
	return out
}

func (s *Store) unreadIncoming(chat string, limit int) []*Row {
	return s.query("where chat = ? and mine = 0 order by ts desc limit ?", chat, limit)
}

func (s *Store) setStatus(chat, id string, status int) bool {
	result, err := s.db.Exec("update messages set status = ? where chat = ? and id = ? and mine = 1 and status < ? and status >= 0", status, chat, id, status)
	if err != nil {
		return false
	}
	changed, _ := result.RowsAffected()
	return changed > 0
}

func (s *Store) search(text string, limit int) []*Row {
	like := "%" + strings.NewReplacer("%", "\\%", "_", "\\_").Replace(text) + "%"
	return s.query("where text like ? escape '\\' order by ts desc limit ?", like, limit)
}

func (s *Store) starred() []*Row {
	return s.query("where data like '%\"starred\":true%' order by ts desc limit 300")
}

// ── reactions and votes ─────────────────────────────────────────────────
func (s *Store) react(chat, id, sender, emoji string, ts int64) {
	if emoji == "" {
		_, _ = s.db.Exec("delete from reactions where chat = ? and id = ? and sender = ?", chat, id, sender)
		return
	}
	_, _ = s.db.Exec("insert or replace into reactions values (?, ?, ?, ?, ?)", chat, id, sender, emoji, ts)
}

// {message id: [[sender, emoji]]} of a chat
func (s *Store) reactions(chat string) map[string][][2]string {
	out := map[string][][2]string{}
	rows, err := s.db.Query("select id, sender, emoji from reactions where chat = ? order by ts", chat)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var id, sender, emoji string
		if rows.Scan(&id, &sender, &emoji) == nil {
			out[id] = append(out[id], [2]string{sender, emoji})
		}
	}
	return out
}

func (s *Store) vote(chat, id, sender string, options []string, ts int64) {
	data, _ := json.Marshal(options)
	_, _ = s.db.Exec("insert or replace into votes values (?, ?, ?, ?, ?)", chat, id, sender, string(data), ts)
}

// {message id: {sender: [option]}} of a chat
func (s *Store) votes(chat string) map[string]map[string][]string {
	out := map[string]map[string][]string{}
	rows, err := s.db.Query("select id, sender, options from votes where chat = ?", chat)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var id, sender, data string
		if rows.Scan(&id, &sender, &data) != nil {
			continue
		}
		var options []string
		_ = json.Unmarshal([]byte(data), &options)
		if out[id] == nil {
			out[id] = map[string][]string{}
		}
		out[id][sender] = options
	}
	return out
}
