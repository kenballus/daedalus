#pragma once

#include <cassert>
#include <memory>
#include <functional>
#include <variant>
#include <boost/context/fiber.hpp>

#include <ddl/boxed.h>
#include <ddl/size.h>
#include <ddl/number.h>
#include <ddl/array.h>
#include <ddl/maybe.h>

namespace DDL {

namespace ctx=boost::context;

using StreamChunkGenericDel = std::function<void(const char*)>;
using StreamChunkDel        = std::function<void()>;

/// The data source for a stream
class StreamData : HasRefs {

  class Chunk: HasRefs {
    Size        size;         // Amount of data in this chunk
    RefCount    ref_count;    // Number of references to this chunk
    const char* buffer;       // Data for the chunk  (nullable)
    Chunk*      next;         // Next chunk, if any  (nullable)
    ctx::fiber* thunk;        // Where to get more data.
                              // Only meaningful on a terminal thunk
    std::variant
      < StreamChunkGenericDel*    // borrowed
      , StreamChunkDel            // owned
      > del;


    // A marker for a terminal empty buffer.
    // If `buffer` points to this then this stream is finished and cannot
    // get any more data.
    inline static const char *emptyBuffer = "";

    /// Deallocate the current node.
    /// @return A pointer to the next node, if any.
    Chunk* freeThis() {
      Chunk *res = next;
      if (buffer != nullptr && buffer != emptyBuffer) {
        if (del.index() == 0) (*std::get<0>(del))(buffer);
        else std::get<1>(del)();
      }
      delete this;
      return res;
    }

    /// Make an empty, non-extensible buffer.
    Chunk()
      : size(0)
      , ref_count(1)
      , buffer(emptyBuffer)
      , next(nullptr)
      , thunk(nullptr)
      , del(nullptr)
      {}

  public:

    /// Make an extensible buffer with no data.
    /// @param getData The context that will provide more data.
    Chunk(ctx::fiber &getData)
      : size(0)
      , ref_count(1)
      , buffer(nullptr)
      , next(nullptr)
      , thunk(&getData)
      , del(nullptr)
      {}

    /// Make a non-extensible single chunk buffer from the given array
    /// Owns the array
    Chunk(Array<UInt<8>> data) {
      auto buf = data.borrowData();
      if (buf == nullptr) {
        *this = Chunk();
      } else {
        size = data.size();
        ref_count = 1;
        buffer = reinterpret_cast<char const*>(buf);
        next = nullptr;
        thunk = nullptr;
        del = StreamChunkDel([data]() mutable { data.free(); });
      }
    }

    /// The address of a staic empty chunk
    static inline Chunk* empty() {
      static Chunk e;
      return &e;
    }

    /// @return `true` if there are no more chunks after this.
    bool isTerminal () const { return next == nullptr; }

    /// @return `true` if we are a finished chunk with no more data.
    bool isEmpty()     const { return buffer == emptyBuffer; }

    /// @return The size of *this* chunk of stream.
    Size getChunkSize() const { return size; }

    /// @param offset  Offset of the element we want.
    /// @return        Element at the given offset of the *current* chunk.
    /// Assumes: offset < size
    UInt<8> elementAt(Size offset) const {
      assert(offset < size);
      return UInt<8>(buffer[offset.rep()]);
    }

    /// Add an extra reference.
    void copy() { ++ref_count; }

    /// Remove a reference.
    /// Owns this.
    void free() {
      for (auto p = this; p != empty() && p != nullptr;) {
        if (p->ref_count > 1) { --(p->ref_count); return; }
        p = p->freeThis();
      }
    }

    /// Assume: !isTerminal()
    /// Owns this.
    /// @return An ownded reference to the next chunk.
    /// Assert: return != nullptr
    Chunk* nextChunk() {
      assert(!isTerminal());

      if (ref_count > 1) {
        --ref_count;
        ++(next->ref_count);
        return next;
      } else
        return freeThis();
    }

    /// Assume: !isTerminal()
    /// @return A borrowed reference to the next chunk.
    /// Assert: return != nullptr
    Chunk* borrowNext() {
      assert(!isTerminal());
      return next;
    }

    /// May suspend execution.
    /// Assumes: isTerminal()
    /// Owns this.
    /// @return returns `true` if we got new data.
    bool tryGetData() {

      if (!isTerminal()) return true;

      while (isTerminal()) {
        if (isEmpty()) return false;
        *thunk = std::move(*thunk).resume();
      }

      return true;
    }

    /// Debug view of the chunks.
    void dump() const {
      for (auto p = this; p != nullptr; p = p->next) {
        std::cout
          << "[" << p->ref_count
          << "|" << (void*) p
          << "|";
        if (p->buffer == nullptr)     std::cout << "thunk"; else
        if (p->buffer == emptyBuffer) std::cout << "empty"; else
          std::cout << (void*)p->buffer;
        std::cout << "]\n";
      }
    }

    /// Copy `len` bytes, starting at `offset` into the give buffer.
    /// @param out      A buffer to copy the bytes into
    /// @param offset   The index of the first byte to copy
    /// @param len      How many bytes to copy.
    /// @return pointer to the element after the last copie one
    char *copyInto(char *out, Size offset, Size len) const {
      assert(buffer != nullptr);
      return std::copy_n(buffer + offset.rep(), len.rep(), out);
    }

    /// Append a new chunk of data to the stream.
    /// Owns this.  Owns buf_del
    /// When we are done with `cbuffer` we call `buf_del`.
    /// Assume: isTerminal() && !isEmpty() && thunk != nullptr
    /// @return An owned reference to the new end of the stream.
    /// Assert: return != nullptr
    Chunk* append( Size csize, const char *cbuffer
                 , StreamChunkDel &&buf_del
                 ) {
      assert (isTerminal());
      assert (!isEmpty());
      assert (thunk != nullptr);

      if (csize == 0) {
        buf_del();
        return this;
      }

      size    = csize;
      buffer  = cbuffer;
      del     = std::move(buf_del);
      next    = new Chunk(*thunk);

      return nextChunk();
    }

    /// Append a new chunk of data to the stream.
    /// Owns this.
    /// When we are done with `cbuffer` we call `buf_del(cbuffer)`.
    /// Assume: isTerminal() && !isEmpty() && thunk != nullptr
    /// Assume: buf_del lives longer then we do (we are borrwoing it).
    /// @return An owned reference to the new end of the stream.
    /// Assert: return != nullptr
    Chunk* append( Size csize, const char *cbuffer
                 , StreamChunkGenericDel &buf_del
                 ) {
      assert (isTerminal());
      assert (!isEmpty());
      assert (thunk != nullptr);

      if (csize == 0) {
        buf_del(cbuffer);
        return this;
      }

      size    = csize;
      buffer  = cbuffer;
      del     = &buf_del;
      next    = new Chunk(*thunk);

      return nextChunk();
    }

    /// Terminate the stream.
    /// Assume: isTerminal()
    void finish() {
      assert(isTerminal());
      buffer = emptyBuffer;
    }



  };





  // ------------------------------------------ //

  Chunk* front;       /// The front of the data.
                      /// Invariant: front != nullptr

public:

  /// Make a new non-extensible empty stream.
  StreamData() : front(Chunk::empty())  {}

  /// Make a new non-extensible stream containing the given array.
  StreamData(Array<UInt<8>> data) : front(new Chunk(data)) {}

  /// Make a new extensible empty stream.
  StreamData(ctx::fiber &getData) : front(new Chunk(getData))  {}

  /// @return `true` if there is currently no data in the stream.
  bool isTerminal ()  const { return front->isTerminal(); }

  /// @return The size of the first chunk in the data.
  Size getChunkSize() const { return front->getChunkSize(); }

  /// Assume: offset < getChunkSize()
  /// @param  offset  The offset of the element we are interested in.
  /// @return         The element at the given offset in the *current* chunk.
  UInt<8> elementAt(Size offset) const {
    assert(offset < getChunkSize());
    return front->elementAt(offset);
  }

  /// Owns this.
  /// Append new buffer.
  /// The data stream is updated to point to the new end of stream.
  /// @param csize    Size of the new data.
  /// @param cbuffer  Data associate with the buffer.
  /// @param del      How to deallocate the data when we are done with it.
  void appendMut(Size csize, const char *cbuffer, StreamChunkGenericDel &d) {
    front = front->append(csize, cbuffer, d);
  }

  void appendMut(Size csize, const char *cbuffer, StreamChunkDel &&d) {
    front = front->append(csize, cbuffer, std::move(d));
  }

  void finishMut() { front->finish(); }

  /// Try to fill a node with data.
  /// Owns this.
  /// May suspend.
  /// @return `true` if more data was available, or `false` if no more data.
  bool tryGetData() {
    front->tryGetData();
    return !front->isEmpty();
  }

  /// Advance to the next chunk.
  /// Owns this.
  /// Assumes: !isTerminal()
  void nextChunkMut() { front = front->nextChunk(); }

  /// Add an extrea reference.
  void copy() { front->copy(); }

  /// Remove a reference.
  /// Owns this.
  void free() { front->free(); }

  /// Debug dump of the available data.
  void dump() const { front->dump(); }

  void copyInto(char *out, Size offset, Size len) const {
    if (len == 0) return;

    auto p = front;
    auto size = p->getChunkSize();
    assert(offset < size);
    auto have = size.decrementedBy(offset);
    if (have > len) have = len;
    out = p->copyInto(out, offset, have);
    len.decrementBy(have);

    while (len > 0) {
      p    = p->borrowNext();
      have = p->getChunkSize();
      assert(have > 0);
      if (have > len) have = len;
      out = p->copyInto(out, 0, have);
      len.decrementBy(have);
    }

  }
};


// -----------------------------------------------------------------------------


/// A consumer of a data, where the data may be provided a little bit a time.
class Stream : HasRefs {

  StreamData data;
  /// The data backing this stream.

  Size chunk_offset;
  /// Offset of the *beginning of the data, relative to the start of the stream.

  Size offset;
  /// Offset relative to the current chunk.
  /// Invariant: chunk_size == 0 || offset < chunk_size

  Size chunk_size;
  /// How much of the chunk is available to us.
  /// This may be less then the size of the chunk, if we have restricted
  /// the stream.

  Size last_offset;
  /// The offset at the end of the stream.
  /// We are only allowed to read at smaller offsets.

  Array<UInt<8>> name;
  /// Name for the stream


  /// Do this when this stream is known to be empty to
  /// let go of the underlying stream
  void makeEmpty() {
    data.free();
    data         = StreamData();
    chunk_offset = getOffset();
    offset       = 0;
    chunk_size   = 0;
  }

  /// Adjust the size of the current chunk.
  void setChunkSize(Size global) {
    chunk_size   = data.getChunkSize();
    Size have    = last_offset.decrementedBy(global);
    if (chunk_size > have) chunk_size = have;
  }

  /// Assumes: !data.isTerminal()
  void advance() {
    Size global = getOffset();
    if (global == last_offset) {
      makeEmpty();
      return;
    }
    data.nextChunkMut();
    offset = 0;
    chunk_offset = global;
    setChunkSize(global);
  }



public:

  /// Make an empty, non-extensible data source.
  Stream()
    : data(StreamData())
    , chunk_offset(0)
    , offset(0)
    , chunk_size(0)
    , last_offset(0)
    , name() {}

  /// Make a new stream using the given data source, starting at offset 0.
  /// @param data  The data to back the stream.  Owned.
  Stream (Array<UInt<8>> name, Array<UInt<8>> data)
    : data(data)
    , chunk_offset(0)
    , offset(0)
    , chunk_size(data.size())
    , last_offset(data.size())
    , name(name)
  {}


  /// Make a new stream using the given data source, starting at offset 0.
  /// @param data  The data to back the stream.  Owned.
  Stream (Array<UInt<8>> name, StreamData data)
    : data(data)
    , chunk_offset(0)
    , offset(0)
    , chunk_size(data.getChunkSize())
    , last_offset(Size::maxValue())
    , name(name)
  {}

  /// Add an extre reference.
  void copy()       { data.copy(); name.copy(); }

  /// Remove a reference.
  /// Owns this.
  void free()       { data.free(); name.free(); }

  /// Debug dump of the data in stream.
  /// XXX: Currently this dumps *all* data, ignoring `last_offset`.
  void dump() const { data.dump(); }

  /// @return the current offset, relative to the beginning of the stream.
  Size getOffset() const {
    return chunk_offset.incrementedBy(offset);
  }

  /// Check to see if the stream is empty.
  /// May suspend.
  /// @return `true` if the stream contains no data,
  ///                and won't be getting any more.
  bool isEmpty() {
    if (offset < chunk_size) return false;  // common case

    Size global = getOffset();
    if (global >= last_offset) return true;

    assert(chunk_size == 0);

    if (!data.tryGetData()) return true;

    setChunkSize(global);
    return false;
  }

  /// Assume: !isEmpty()
  /// @return The front element of the stream.
  UInt<8> iHead() const {
    return data.elementAt(offset);
  }

  bool iDropMut1() {
    if (isEmpty()) return false;
    offset.increment();
    if (offset == chunk_size) advance();
    return true;
  }

  /// Advance the current offset by this much.
  /// Mutable own this.
  /// @param nHow many bytes to advance by.
  /// @return How many bytes were NOT dropped. If all requested
  ///         bytes were dropped reutrns 0, but if the data run out before then
  ///         it will return how many bytes still needed to be dropped.
  Size iDropMut(Size n) {

    while (n > 0 && !isEmpty()) {

      Size have = chunk_size.decrementedBy(offset);
      if (n < have) {
        offset.incrementBy(n);
        return 0;
      } else {
        offset.incrementBy(have);
        n.decrementBy(have);
        Size global = getOffset();
        if (global == last_offset) {
          makeEmpty();
          break;
        }
        advance();
      }
    }
    return n;
  }

  /// Restrict the stream to at most the given number of bytes.
  /// Note that this does *not* ensure that the given number of bytes
  /// is present in the stream, only that we won't consume more than this much.
  /// Mutable owns this.
  /// @param n Limit the stream to this many bytes.
  void iTakeMut(Size n) {
    if (n == 0) {
      makeEmpty();
      return;
    }

    Size global = getOffset();
    Size have   = last_offset.decrementedBy(global);
    if (n >= have) return;

    last_offset = global.incrementedBy(n);
    have = have.decrementedBy(n);
    if (chunk_size > have) chunk_size = have;
  }

  /// Create a new stream that is the same as the current one,
  /// except it won't consume more than the given number of bytes.
  /// Owns this.
  /// @param n  How many bytes is the limit.
  /// @return   A new stream with the requested restriction.
  Stream iTake(Size n) const {
    Stream res(*this);
    res.iTakeMut(n);
    return res;
  }

  /// Create a new stream by skipping some bytes from the current stream.
  /// If the underlying data backing the stream has less data than we drop,
  /// then we only drop to the end of the data.
  /// Owns this.
  /// May suspend.
  /// @param n    How many bytes to skip.
  /// @return     A new stream advanced by the requested amount, or less
  ///             if the data runs out.
  Stream iDrop(Size n) const {
    Stream res(*this);
    res.iDropMut(n);
    return res;
  }

  /// Create a new stream by skipping some bytes from the current stream.
  /// Returns `nothing` if there isn't enought data to drop.
  /// Owns this.
  /// Maybe suspend.
  /// @param n    How many bytes to skip.
  /// @return     A new stream advanced by the requested amount, or nothing.
  Maybe<Stream> iDropMaybe(Size n) const {
    Stream res(*this);
    if (res.iDropMut(n) == 0) return Maybe(res);
    res.free();
    return Maybe<Stream>();
  }

  /// Check if the given string is a prfiex of the input.
  /// May suspend.
  /// Returns `true` if the given bytes are a prefix of the stream,
  /// and `false` if they are not.
  bool hasPrefix(Array<UInt<8>> pref) {
    Size n = pref.size();
    Stream peek(*this);
    peek.copy();
    bool yes = true;
    for (Size i = 0; i < n; i.increment()) {
      if (peek.isEmpty() || peek.iHead() != pref[i]) { yes = false; break; }
      peek.iDropMut1();
    }
    peek.free();
    return yes;
  }

  Array<UInt<8>> getName()          { name.copy(); return name; }
  Array<UInt<8>> borrowName() const { return name; }
  std::string_view borrowNameBytes() const { return name.borrowBytes(); }

  /// Compute the number of bytes in the stream.
  /// May suspend. Will wait until the stream is terminated.
  Size length() const {
    Size n = 0;
    Stream peek(*this);
    peek.copy();
    while (!peek.isEmpty()) {
      auto have = peek.chunk_size.decrementedBy(peek.offset);
      n.incrementBy(have);
      peek.offset.incrementBy(have);
      peek.advance();
    }
    peek.free();
    return n;
  }

  /// Copy all bytes from the stream into an array.
  /// May suspend. Will wait until the stream is terminated.
  Array<UInt<8>> getByteArray() const {
    auto n        = length();
    auto *content = Array<UInt<8>>::Content::allocate(n);
    char *out     = reinterpret_cast<char*>(content->data);
    data.copyInto(out, offset, n);
    return Array<UInt<8>>{content};
  }

  /// We compare by name, not the actual byte content.
  friend
  int compare(Stream x, Stream y) {
    if (x.offset < y.offset) return -1;
    if (x.offset > y.offset) return 1;
    if (x.last_offset < y.last_offset) return -1;
    if (x.last_offset > y.last_offset) return 1;
    return compare(x.name,y.name);
  }


  // XXX: We need to esacpe quotes in the input name
  friend
  std::ostream& operator<<(std::ostream& os, Stream x) {
    os << "Stream(\"" << (char*)x.name.borrowData()
                   << "\":0x" << std::hex << x.offset;
    if (x.last_offset < Size::maxValue()) {
       os << "--0x" << std::hex << x.last_offset;
     }
     os << ")";

     return os;
  }

  // XXX: We need to esacpe quotes in the input name
  friend
  std::ostream& toJS(std::ostream& os, Stream x) {
    os << "{ \"$$input\": \"" << (char*)x.name.borrowData()
                   << ":0x" << std::hex << x.offset;
    if (x.last_offset < Size::maxValue()) {
      os << "--0x" << std::hex << x.last_offset;
    }
    os << "\"}";

    return os;
  }

};


// Borrow arguments
static inline
bool operator == (Stream xs, Stream ys) { return compare(xs,ys) == 0; }

// Borrow arguments
static inline
bool operator < (Stream xs, Stream ys) { return compare(xs,ys) < 0; }

// Borrow arguments
static inline
bool operator > (Stream xs, Stream ys) { return compare(xs,ys) > 0; }

// Borrow arguments
static inline
bool operator != (Stream xs, Stream ys) { return !(xs == ys); }

// Borrow arguments
static inline
bool operator <= (Stream xs, Stream ys) { return !(xs > ys); }

// Borrow arguments
static inline
bool operator >= (Stream xs, Stream ys) { return !(xs < ys); }






/// Encapsulates the interaction between a parser and a separate corouting
/// that fills the parser's data stream.
class ParserThread {
  ctx::fiber            context;   /// The context of the suspended party.
  StreamData            data;      /// The data stream to be parserd.
  StreamChunkGenericDel del;       /// Use this to deallocate buffers
  bool                  done;      /// Is the parser finished parsing.

public:

  /// Initialize the data stream.
  /// @param parser The consumer of the stream.
  ///               Will be called with a Stream value
  template <typename Fn>
  ParserThread(const char* name, StreamChunkGenericDel &&d, Fn &&parser)
    : ParserThread
        ( Array{reinterpret_cast<UInt<8> const*>(name), strlen(name)}
        , std::move(d)
        , std::move(parser)
        ) {}

  /// Initialize the data stream.
  /// @param parser The consumer of the stream.
  ///               Will be called with a Stream value
  template <typename Fn>
  ParserThread(const char* name, Fn &&parser)
    : ParserThread
        ( Array{reinterpret_cast<UInt<8> const*>(name), strlen(name)}
        , std::move(parser)
        ) {}

  /// Initialize the data stream.
  /// Owns name
  /// @param parser The consumer of the stream.
  ///               Will be called with a Stream value
  template <typename Fn>
  ParserThread(Array<UInt<8>> name, Fn &&parser)
    : ParserThread
        ( name
        , [](const char* _x) { assert(false); }
        , std::move(parser)
        ) {}


  /// Initialize the data stream.
  /// Owns name
  /// @param parser The consumer of the stream.
  ///               Will be called with a Stream value
  template <typename Fn>
  ParserThread(Array<UInt<8>> name, StreamChunkGenericDel &&d, Fn &&parser)
    : context(
        [this,name,parser] (ctx::fiber &&top) {
          context = std::move(top);
          data.copy();
          parser(Stream(name,data));
          done = true;
          return std::move(context);
        })
    , data(StreamData(context))
    , del(std::move(d))
    , done(false)
    {}



  ~ParserThread() { data.free(); }

  /// Resume the parser, after it had suspended 
  /// Should only be run *after* `start`.
  /// Assumes: !isDone()
  void resume() { context = std::move(context).resume(); }

  /// Check if the parser has finished parsing.
  bool isDone() const { return done; }

  /// Provide more data to the parser.
  void append(size_t csize, const char* bytes) {
    data.appendMut(csize, bytes, del);
  }

  /// Provide more data to the parser, with a custom delete function
  /// We own the delete function
  void append(size_t csize, const char* bytes, StreamChunkDel &&d) {
    data.appendMut(csize, bytes, std::move(d));
  }



  /// Terminate the data stream.
  void finish() { data.finishMut(); }
};




}
