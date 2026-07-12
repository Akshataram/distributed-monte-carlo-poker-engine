package redisagg

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Client struct {
	mu       sync.Mutex
	conn     net.Conn
	reader   *bufio.Reader
	addr     string
	username string
	password string
	useTLS   bool
	timeout  time.Duration
}

func (c *Client) Do(ctx context.Context, args ...string) (any, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if err := c.ensureConn(ctx); err != nil {
		return nil, err
	}
	reply, err := c.do(ctx, args...)
	if err != nil {
		c.close()
		return nil, err
	}
	return reply, nil
}

func (c *Client) ensureConn(ctx context.Context) error {
	if c.conn != nil {
		return nil
	}
	conn, err := dial(ctx, c.addr, c.useTLS, c.timeout)
	if err != nil {
		return err
	}
	c.conn = conn
	c.reader = bufio.NewReader(conn)
	if c.password != "" {
		args := []string{"AUTH", c.password}
		if c.username != "" {
			args = []string{"AUTH", c.username, c.password}
		}
		if _, err := c.do(ctx, args...); err != nil {
			c.close()
			return err
		}
	}
	return nil
}

func (c *Client) do(ctx context.Context, args ...string) (any, error) {
	if deadline, ok := ctx.Deadline(); ok {
		_ = c.conn.SetDeadline(deadline)
	} else {
		_ = c.conn.SetDeadline(time.Now().Add(c.timeout))
	}
	if _, err := c.conn.Write(encodeCommand(args)); err != nil {
		return nil, err
	}
	return readReply(c.reader)
}

func (c *Client) close() {
	if c.conn != nil {
		_ = c.conn.Close()
	}
	c.conn = nil
	c.reader = nil
}

func encodeCommand(args []string) []byte {
	var buf bytes.Buffer
	fmt.Fprintf(&buf, "*%d\r\n", len(args))
	for _, arg := range args {
		fmt.Fprintf(&buf, "$%d\r\n%s\r\n", len(arg), arg)
	}
	return buf.Bytes()
}

func readReply(r *bufio.Reader) (any, error) {
	prefix, err := r.ReadByte()
	if err != nil {
		return nil, err
	}
	switch prefix {
	case '+':
		return readLine(r)
	case '-':
		line, _ := readLine(r)
		return nil, errors.New(line)
	case ':':
		line, err := readLine(r)
		if err != nil {
			return nil, err
		}
		return strconv.ParseInt(line, 10, 64)
	case '$':
		return readBulk(r)
	case '*':
		line, err := readLine(r)
		if err != nil {
			return nil, err
		}
		n, err := strconv.Atoi(line)
		if err != nil {
			return nil, err
		}
		out := make([]any, 0, n)
		for i := 0; i < n; i++ {
			value, err := readReply(r)
			if err != nil {
				return nil, err
			}
			out = append(out, value)
		}
		return out, nil
	default:
		return nil, fmt.Errorf("unknown redis reply prefix %q", prefix)
	}
}

func readLine(r *bufio.Reader) (string, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r"), nil
}

func readBulk(r *bufio.Reader) (string, error) {
	line, err := readLine(r)
	if err != nil {
		return "", err
	}
	n, err := strconv.Atoi(line)
	if err != nil {
		return "", err
	}
	if n == -1 {
		return "", nil
	}
	buf := make([]byte, n+2)
	if _, err := io.ReadFull(r, buf); err != nil {
		return "", err
	}
	return string(buf[:n]), nil
}
