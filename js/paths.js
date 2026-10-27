// A path as one string: its ids joined with a dash. Ids are [0-9a-z], so a dash never occurs in
// one, and the key needs no escaping in a URL, a class name or a data attribute. The root's key
// is the empty string - where it has to be seen, call it "root". As a DOM id, prefix it: an id
// that starts with a digit needs CSS.escape in a selector
export const pathKey = (path) => path.join("-")

export const pathFromKey = (key) => (key === "" ? [] : key.split("-"))
