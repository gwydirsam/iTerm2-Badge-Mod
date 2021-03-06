//
//  VT100TmuxParser.m
//  iTerm
//
//  Created by George Nachman on 3/10/14.
//
//

#import "VT100TmuxParser.h"
#import "NSMutableData+iTerm.h"

@interface VT100TmuxParser ()
@property(nonatomic, retain) NSString *currentCommandId;
@property(nonatomic, retain) NSString *currentCommandNumber;
@end

@implementation VT100TmuxParser {
    BOOL _inResponseBlock;
    NSMutableData *_line;
}

- (void)dealloc {
    [_currentCommandId release];
    [_currentCommandNumber release];
    [_line release];
    [super dealloc];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _line = [[NSMutableData alloc] init];
    }
    return self;
}

- (NSString *)hookDescription {
    return @"[TMUX GATEWAY]";
}

- (BOOL)handleInput:(iTermParserContext *)context token:(VT100Token *)result {
    int bytesTilNewline = iTermParserNumberOfBytesUntilCharacter(context, '\n');
    if (bytesTilNewline == -1) {
        // No newline to be found. Append everything that is available to |_line|.
        int length = iTermParserLength(context);
        [_line appendBytes:iTermParserPeekRawBytes(context, length)
                    length:length
            excludingCharacter:'\r'];
        iTermParserAdvanceMultiple(context, length);
        result->type = VT100_WAIT;
    } else {
        // Append bytes upt to the newline, stripping out linefeeds. Consume the newline.
        [_line appendBytes:iTermParserPeekRawBytes(context, bytesTilNewline)
                    length:bytesTilNewline
            excludingCharacter:'\r'];
        iTermParserAdvanceMultiple(context, bytesTilNewline + 1);

        // Tokenize the line, returning if it is a terminator like %exit.
        if ([self processLineIntoToken:result]) {
            return YES;
        }
    }
    return NO;
}

// Return YES if we should unhook.
- (BOOL)processLineIntoToken:(VT100Token *)result {
    result.savedData = [[_line copy] autorelease];
    NSString *command =
        [[[NSString alloc] initWithData:_line encoding:NSUTF8StringEncoding] autorelease];

    if (!command) {
        // The command was not UTF-8. Unfortunately, this can happen. If tmux has a non-UTF-8
        // character in a pane, it will just output it in capture-pane.
        command = [[[NSString alloc] initWithUTF8DataIgnoringErrors:_line] autorelease];
    }
    result->type = TMUX_LINE;
    [_line setLength:0];

    BOOL unhook = NO;
    if (_inResponseBlock) {
        if ([command hasPrefix:@"%exit"]) {
            // Work around a bug in tmux 1.8: if unlink-window causes the current
            // session to be destroyed, no end guard is printed but %exit may be
            // received.
            // I submitted a patch to tmux on 4/6/13, but it's not clear how long the
            // workaround should stick around.
            // TODO: test tmux 1.9 and make sure this code can be removed, then remove it.
            result->type = TMUX_EXIT;
            _inResponseBlock = NO;
            unhook = YES;
        } else if ([command hasPrefix:@"%end "] ||
                   [command hasPrefix:@"%error "]) {
            NSArray *parts = [command componentsSeparatedByString:@" "];
            if (parts.count >= 3 &&
                [_currentCommandId isEqual:parts[1]] &&
                [_currentCommandNumber isEqual:parts[2]]) {
                _inResponseBlock = NO;
            }
        }
    } else {
        if ([command hasPrefix:@"%begin"]) {
            NSArray *parts = [command componentsSeparatedByString:@" "];
            if (parts.count >= 3) {
                self.currentCommandId = parts[1];
                self.currentCommandNumber = parts[2];
                _inResponseBlock = YES;
            }
        } else if ([command hasPrefix:@"%exit"]) {
            result->type = TMUX_EXIT;
            unhook = YES;
        }
    }
    result.string = command;

    return unhook;
}

@end
