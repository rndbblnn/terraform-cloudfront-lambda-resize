import { PassThrough, Readable } from 'stream';
import sharp from 'sharp';
import type { CloudFrontRequestHandler, CloudFrontRequestEvent } from 'aws-lambda';
import { S3Client, HeadObjectCommand, NotFound, GetObjectCommand, GetObjectCommandOutput, NoSuchKey } from '@aws-sdk/client-s3';
import { Upload } from "@aws-sdk/lib-storage";
const s3Client = new S3Client({ region: 'us-east-1' });
const matchUriRegExp = new RegExp(`^/(.*)-({0-9}*x{0-9}*)$`);

const doesObjectExists = async (bucket: string, key: string): Promise<boolean> => {
    try {
        await s3Client.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
        return true;
    } catch (err) {
        if (err instanceof NotFound) {
            return false;
        }
        throw err;
    }
};

const getObject = async (bucket: string, key: string): Promise<null | GetObjectCommandOutput> => {
    try {
        return await s3Client.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    } catch (err) {
        if (err instanceof NoSuchKey) {
            return null;
        }
        throw err;
    }
}

export const handler: CloudFrontRequestHandler = async (event: CloudFrontRequestEvent) => {
// exports.handler = async event => {
    const { request } = event.Records[0].cf;
    // check if request includes dimensions (there's no need to run resizing for fetching original image)
    const matchedUri = request.uri.match(matchUriRegExp);
    if (matchedUri === null) {
        return request;
    }
    const s3DomainName = request.headers.host[0].value;
    const bucket = s3DomainName.split('.')[0];
    const requestedKey = request.uri.substring(1);
    // check if resized image already exists, if so pass request to S3
    if (await doesObjectExists(bucket, requestedKey)) {
        return request;
    }
    const [, originalKey, dimensions] = matchedUri;
    const [width, height] = dimensions.split('x');
    const originalImage = await getObject(bucket, originalKey);
    // if original image to resize does not exist pass req to S3 (which will handle not found error)
    if (!originalImage) {
        return request;
    }
    // use streaming to handle downloading, resizing and uploading resized file to S3
    const resizeStream = sharp()
        .rotate()
        .resize({
            width: Number(width),
            height: Number(height),
            fit: sharp.fit.inside,
            withoutEnlargement: true,
        })
        .webp();
    const passThrough = new PassThrough();
    const upload = new Upload({
        client: s3Client,
        params: {
            Bucket: bucket,
            Key: requestedKey,
            Body: passThrough,
            ContentType: 'image/webp',
        },
    });
    (originalImage.Body as Readable).pipe(resizeStream).pipe(passThrough);
    await upload.done();

    // console.log('Data: ', {
    //     s3DomainName: s3DomainName,
    //     matchedUri: matchedUri
    // });

    return request;
};