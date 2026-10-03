package http

import (
	"fmt"
	"net/http"
)

// Reject a full response to a range request before writing it into a later file
// offset. This is also the If-Range signal that Android uses to restart safely.
func validateRangeResponse(req *http.Request, resp *http.Response, total int64) error {
	if req.Header.Get("Range") == "" {
		return nil
	}
	var start, end, gotStart, gotEnd, gotTotal int64
	n, err := fmt.Sscanf(req.Header.Get("Range"), "bytes=%d-%d", &start, &end)
	if err != nil || n != 2 {
		return NewRequestError(412, "invalid request range")
	}
	n, err = fmt.Sscanf(resp.Header.Get("Content-Range"), "bytes %d-%d/%d", &gotStart, &gotEnd, &gotTotal)
	if resp.StatusCode != http.StatusPartialContent || err != nil || n != 3 || start != gotStart || end != gotEnd || (total > 0 && total != gotTotal) {
		return NewRequestError(412, "remote range changed")
	}
	return nil
}
