module http

import io
import net { TcpConn }
import net.urllib
import encoding.base64
import time

pub interface ProxyConnLayer {
mut:
	read(mut buf []byte) ?int
	write(buf []byte) ?int
	close() ?
	set_read_timeout(timeout time.Duration)
	set_write_timeout(timeout time.Duration)
}

struct PlainConnLayer {
	TcpConn
}

fn (mut l PlainConnLayer) write(buf []byte) ?int {
	return l.TcpConn.write(buf)
}

fn (mut l PlainConnLayer) read(mut bytes []byte) ?int {
	return l.TcpConn.read(mut bytes)
}

fn (mut l PlainConnLayer) close() ? {
	l.TcpConn.close() ?
}

fn (mut l PlainConnLayer) set_read_timeout(t time.Duration) {
	l.TcpConn.set_read_timeout(t)
}

fn (mut l PlainConnLayer) set_write_timeout(t time.Duration) {
	l.TcpConn.set_write_timeout(t)
}

struct HttpProxy {
mut:
	scheme   string
	userinfo urllib.Userinfo
	host     string
	hostname string
	port     int
	url      string

	validate               bool = true
	verify                 string
	cert                   string
	cert_key               string
	in_memory_verification bool

	has_conn    bool
	remote_host string
pub mut:
	conn ProxyConnLayer = ProxyConnLayer(PlainConnLayer{})
}

pub fn new_http_proxy(raw_url string) ?HttpProxy {
	mut url := urllib.parse(raw_url) or { return error('malformed proxy url') }
	scheme := url.scheme

	if scheme != 'http' && scheme != 'https' {
		return error('invalid scheme')
	}

	url.path = ''
	url.raw_path = ''
	url.raw_query = ''
	url.fragment = ''

	str_url := url.str()

	mut host := url.host
	mut port := url.port().int()

	if port == 0 {
		if scheme == 'https' {
			port = 443
		} else if scheme == 'http' {
			port = 80
		}

		host += ':' + port.str()
	}

	return HttpProxy{
		scheme: scheme
		userinfo: url.user
		host: host
		hostname: url.hostname()
		port: port
		url: str_url
	}
}

fn (proxy HttpProxy) build_proxy_headers(request &Request, host string) string {
	ua := request.user_agent
	mut uheaders := []string{}

	uheaders << 'Host: $host\r\n'
	uheaders << 'User-Agent: $ua\r\n'
	uheaders << 'Proxy-Connection: Keep-Alive\r\n'

	if proxy.userinfo.username != '' {
		mut authinfo := ''

		authinfo += proxy.userinfo.username
		if proxy.userinfo.password_set {
			authinfo += ':' + proxy.userinfo.password
		}

		encoded_authinfo := base64.encode(authinfo.bytes())

		uheaders << 'Proxy-Authorization: Basic $encoded_authinfo\r\n'
	}

	version := Version.v1_1

	return 'CONNECT $host $version\r\n' + uheaders.join('') + '\r\n'
}

fn (mut proxy HttpProxy) create_conn_layer() ?ProxyConnLayer {
	if proxy.scheme == 'http' {
		tcp_connection := net.dial_tcp(proxy.host) ?
		return PlainConnLayer{tcp_connection}
	} else if proxy.scheme == 'https' {
		return proxy.create_ssl_layer(proxy.hostname, proxy.port)
	} else {
		return error('wrong schema')
	}
}

pub fn (mut proxy HttpProxy) prepare(request &Request, host string) ? {
	// the case when the connection is dropped also has to be treated
	if proxy.has_conn == false || proxy.remote_host != host {
		proxy.reset_connection() ?
		proxy.open_connection(request, host) ?
	}
}

pub fn (mut proxy HttpProxy) open_connection(request &Request, host string) ? {
	$if trace_http_proxy ? {
		eprintln('<<< HttpProxy.open_connection  | host: $host')
	}

	proxy_headers := proxy.build_proxy_headers(request, host)

	mut client := proxy.create_conn_layer() ?

	mut proxy_reader := io.new_buffered_reader(reader: client as io.Reader)

	client.write(proxy_headers.bytes()) ?

	mut proxy_response_status := proxy_reader.read_line() ?
	mut last_str := proxy_response_status

	for last_str != '' {
		last_str = proxy_reader.read_line() ?
	}

	_, status_code, status_msg := parse_status_line(proxy_response_status) ?

	if status_code < 200 || status_code >= 300 {
		return error('could not connect to proxy: $status_code $status_msg')
	}

	proxy_reader.free()

	$if trace_http_proxy ? {
		eprintln('<<< HttpProxy.open_connection  | connection opened successfully')
	}

	proxy.conn = client
	proxy.remote_host = host
}

pub fn (mut proxy HttpProxy) reset_connection() ?bool {
	if proxy.has_conn == false {
		return false
	}

	proxy.conn.close() ?
	proxy.remote_host = ''
	proxy.has_conn = false

	return true
}
