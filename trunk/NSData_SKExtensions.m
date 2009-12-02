//
//  NSData_SKExtensions.m
//  Skim
//
//  Created by Christiaan Hofman on 9/8/07.
/*
 This software is Copyright (c) 2007-2009
 Christiaan Hofman. All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions
 are met:

 - Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

 - Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

 - Neither the name of Christiaan Hofman nor the names of any
    contributors may be used to endorse or promote products derived
    from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "NSData_SKExtensions.h"
#import "NSGeometry_SKExtensions.h"
#import "SKRuntime.h"
#import <openssl/bio.h>
#import <openssl/evp.h>
#import <CommonCrypto/CommonDigest.h>

@implementation NSData (SKExtensions)

- (NSRange)Leopard_rangeOfData:(NSData *)dataToFind options:(NSDataSearchOptions)mask range:(NSRange)searchRange {
    NSUInteger patternLength = [dataToFind length];
    NSUInteger selfLength = [self length];
    
    if (searchRange.location > selfLength || NSMaxRange(searchRange) > selfLength)
        [NSException raise:NSRangeException format:@"Range {%lu,%lu} exceeds length %lu", (unsigned long)searchRange.location, (unsigned long)searchRange.length, (unsigned long)selfLength];
    
    // This test is a nice shortcut, but it's also necessary to avoid crashing: zero-length NSDatas will sometimes(?) return NULL for their bytes pointer, and the resulting pointer arithmetic can underflow.
    if (patternLength == 0 || patternLength > searchRange.length)
        return NSMakeRange(NSNotFound, 0);
    
    const void *patternBytes = [dataToFind bytes];
    const unsigned char *selfBufferStart, *selfPtr, *selfPtrEnd, *selfPtrMax;
    const unsigned char firstPatternByte = *(const char *)patternBytes;
    BOOL backward = (mask & NSDataSearchBackwards) != 0;
    BOOL anchored = (mask & NSDataSearchAnchored) != 0;
    
    selfBufferStart = [self bytes];
    selfPtrMax = selfBufferStart + NSMaxRange(searchRange) + 1 - patternLength;
    if (backward) {
        selfPtr = selfPtrMax - 1;
        selfPtrEnd = selfBufferStart + searchRange.location - 1;
    } else {
        selfPtr = selfBufferStart + searchRange.location;
        selfPtrEnd = selfPtrMax;
    }
    
    for (;;) {
        if (memcmp(selfPtr, patternBytes, patternLength) == 0)
            return NSMakeRange(selfPtr - selfBufferStart, 0);
        
        if (anchored)
            break;
        
        if (backward) {
            do {
                selfPtr--;
            } while (*selfPtr != firstPatternByte && selfPtr > selfPtrEnd);
            if (*selfPtr != firstPatternByte)
                break;
        } else {
            selfPtr++;
            if (selfPtr == selfPtrEnd)
                break;
            selfPtr = memchr(selfPtr, firstPatternByte, (selfPtrMax - selfPtr));
            if (selfPtr == NULL)
                break;
        }
    }
    return NSMakeRange(NSNotFound, 0);
}

- (NSString *)md5String {
    CC_MD5_CTX md5context;
    NSUInteger signatureLength = CC_MD5_DIGEST_LENGTH;
    unsigned char signature[signatureLength];
    NSUInteger blockSize = 4096;
    char buffer[blockSize];
    NSUInteger length = [self length];
    NSRange range = NSMakeRange(0, MIN(blockSize, length));
    
    CC_MD5_Init(&md5context);
    while (range.length > 0) {
        [self getBytes:buffer range:range];
        CC_MD5_Update(&md5context, (const void *)buffer, (CC_LONG)range.length);
        range.location = NSMaxRange(range);
        range.length = MIN(blockSize, length - range.location);
    }
    CC_MD5_Final(signature, &md5context);
    
    NSMutableString *md5String = [NSMutableString stringWithCapacity:signatureLength];
    NSUInteger i;
    
    for (i = 0; i < signatureLength; i++)
        [md5String appendFormat:@"%02x", signature[i]];
    
    return md5String;
}

// base 64 encoding/decoding methods modified from sample code on CocoaDev http://www.cocoadev.com/index.pl?BaseSixtyFour

- (id)initWithBase64String:(NSString *)base64String {
    // Create a memory buffer containing Base64 encoded string data
    BIO *mem = BIO_new_mem_buf((void *)[base64String cStringUsingEncoding:NSASCIIStringEncoding], [base64String lengthOfBytesUsingEncoding:NSASCIIStringEncoding]);
    
    // Push a Base64 filter so that reading from the buffer decodes it
    BIO *b64 = BIO_new(BIO_f_base64());
    BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
    mem = BIO_push(b64, mem);
    
    // Decode into an NSMutableData
    NSMutableData *data = [[NSMutableData alloc] init];
    char inbuf[512];
    NSInteger inlen;
    while ((inlen = BIO_read(mem, inbuf, sizeof(inbuf))) > 0)
        [data appendBytes:inbuf length:inlen];
    
    // Clean up and go home
    BIO_free_all(mem);
    
    self = [self initWithData:data];
    [data release];
    
    return self;
}

- (NSString *)base64StringWithNewlines:(BOOL)encodeWithNewlines {
    // Create a memory buffer which will contain the Base64 encoded string
    BIO *mem = BIO_new(BIO_s_mem());
    
    // Push on a Base64 filter so that writing to the buffer encodes the data
    BIO *b64 = BIO_new(BIO_f_base64());
    if (encodeWithNewlines == NO)
        BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
    mem = BIO_push(b64, mem);
    
    // Encode all the data
    int rv = BIO_write(mem, [self bytes], [self length]);
    rv = BIO_flush(mem);
    
    // Create a new string from the data in the memory buffer
    char *base64Pointer;
    long base64Length = BIO_get_mem_data(mem, &base64Pointer);
    NSString *base64String = [[[NSString alloc] initWithBytes:base64Pointer length:base64Length encoding:NSASCIIStringEncoding] autorelease];
    
    // Clean up and go home
    BIO_free_all(mem);
    return base64String;
}

- (NSString *)base64String {
    return [self base64StringWithNewlines:NO];
}

#pragma mark Templating support

- (NSString *)xmlString {
    return [self base64StringWithNewlines:YES];
}

#pragma mark Scripting support

+ (NSData *)dataWithPointAsQDPoint:(NSPoint)point {
    Point qdPoint = SKQDPointFromNSPoint(point);
    return [self dataWithBytes:&qdPoint length:sizeof(Point)];
}

+ (NSData *)dataWithRectAsQDRect:(NSRect)rect {
    Rect qdRect = SKQDRectFromNSRect(rect);
    return [self dataWithBytes:&qdRect length:sizeof(Rect)];
}

- (NSPoint)pointValueAsQDPoint {
    NSPoint point = NSZeroPoint;
    if ([self length] == sizeof(Point)) {
        const Point *qdPoint = (const Point *)[self bytes];
        point = SKNSPointFromQDPoint(*qdPoint);
    }
    return point;
}

- (NSRect)rectValueAsQDRect {
    NSRect rect = NSZeroRect;
    if ([self length] == sizeof(Rect)) {
        const Rect *qdRect = (const Rect *)[self bytes];
        rect = SKNSRectFromQDRect(*qdRect);
    }
    return rect;
}

+ (id)scriptingPdfWithDescriptor:(NSAppleEventDescriptor *)descriptor {
    return [descriptor data];
}

- (id)scriptingPdfDescriptor {
    return [NSAppleEventDescriptor descriptorWithDescriptorType:'PDF ' data:self];
}

+ (id)scriptingTiffPictureWithDescriptor:(NSAppleEventDescriptor *)descriptor {
    return [descriptor data];
}

- (id)scriptingTiffPictureDescriptor {
    return [NSAppleEventDescriptor descriptorWithDescriptorType:'TIFF' data:self];
}

+ (void)load {
    // this should do nothing on Snow Leopard
    SKAddInstanceMethodImplementationFromSelector(self, @selector(rangeOfData:options:range:), @selector(Leopard_rangeOfData:options:range:));
}

@end
