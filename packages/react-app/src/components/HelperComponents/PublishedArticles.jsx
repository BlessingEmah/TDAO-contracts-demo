import axios from "axios";
import { lazy, Suspense, useEffect, useState } from "react";
import { useHistory, useLocation } from "react-router-dom";

const PublishedArticleCard = lazy(() => import("./PublishedArticleCard.jsx"));

const PublishedArticles = ({ address }) => {
  return (
    <div className="flex flex-col bg-white p-8">
      <div className="flex flex-row mb-6 place-content-between">
        <div className="ml-1 -mt-1 font-bold cursor-pointer text-lg">Published</div>
      </div>
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
        <Suspense fallback={<div>Loading Submission Card...</div>}>
          <PublishedArticleCard></PublishedArticleCard>
          <PublishedArticleCard></PublishedArticleCard>
          <PublishedArticleCard></PublishedArticleCard>
          <PublishedArticleCard></PublishedArticleCard>
        </Suspense>
      </div>
    </div>
  );
};

export default PublishedArticles;
